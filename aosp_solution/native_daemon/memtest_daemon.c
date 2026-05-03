/*
 * memtest_daemon.c
 *
 * Daemon de factory test que roda como root via init.rc.
 * Escuta em /dev/socket/memtest_daemon, executa scripts shell
 * e faz streaming do output de volta para o APK.
 *
 * Protocolo (texto, linhas terminadas em \n):
 *
 *   APK envia:
 *     RUN <script>
 *     KEY=VALUE        (zero ou mais linhas de variaveis)
 *     KEY2=VALUE2
 *     END
 *
 *   <script> ∈ { full_memtest, ram_diagnostic }
 *
 *   Daemon responde:
 *     [DAEMON] ...                (mensagens proprias)
 *     <output do script>
 *     EXIT:<n>                    (codigo de saida do script)
 *
 *   Daemon fecha a conexao.
 *
 *   Comando especial:
 *     KILL                         (mata um run em andamento — opcional)
 */

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define SOCKET_NAME  "memtest_daemon"
#define SCRIPT_DIR   "/system_ext/etc/factory"
#define MAX_LINE     512
#define MAX_ENV      64
#define BUF_SIZE     4096

/* Variaveis aceitas pelo daemon. Filtramos por seguranca para evitar
 * que o cliente injete env arbitraria como PATH, LD_PRELOAD etc. */
static const char *const ALLOWED_KEYS[] = {
    "MIN_WRITE_MBPS",
    "MIN_READ_MBPS",
    "EXPECTED_RAM_GB",
    "EXPECTED_STORAGE_GB",
    "STORAGE_TEST_SIZE_MB",
    "QUICK_MEMTEST_PERCENT",
    "QUICK_MEMTEST_MAX_MB",
    "QUICK_MEMTEST_MIN_MB",
    "QUICK_MEMTEST_LOOPS",
    "QUICK_MEMTEST_TIMEOUT_S",
    "MEMTEST_PERCENT",
    "MEMTEST_MAX_MB",
    "MEMTEST_LOOPS",
    "MEMTEST_TIMEOUT_S",
    "MIN_MEMTEST_MB",
    "DEVICE_NAME",
    "DEVICE_MANUFACTURER",
    NULL,
};

static int key_is_allowed(const char *key) {
    for (int i = 0; ALLOWED_KEYS[i] != NULL; i++) {
        if (strcmp(key, ALLOWED_KEYS[i]) == 0) return 1;
    }
    return 0;
}

/* Sanitiza valor: aceita apenas chars imprimiveis, sem \n, sem ' nem " */
static int value_is_safe(const char *val) {
    if (val == NULL) return 0;
    for (const char *p = val; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c < 32 || c == 127) return 0;
        if (c == '\'' || c == '"' || c == '`' || c == '$' || c == '\\') return 0;
    }
    return 1;
}

static void write_all(int fd, const char *buf, ssize_t len) {
    ssize_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, buf + written, len - written);
        if (n <= 0) break;
        written += n;
    }
}

static void send_line(int client_fd, const char *line) {
    write_all(client_fd, line, (ssize_t)strlen(line));
}

/* Le uma linha do socket ate '\n' ou EOF.
 * Retorna 0 em EOF/erro, >0 = bytes lidos (sem o \n).
 * out_buf eh terminado com \0. */
static ssize_t read_line(int fd, char *out_buf, size_t cap) {
    size_t pos = 0;
    while (pos + 1 < cap) {
        char c;
        ssize_t n = read(fd, &c, 1);
        if (n <= 0) {
            if (pos == 0) return 0;
            break;
        }
        if (c == '\n') break;
        if (c != '\r') {
            out_buf[pos++] = c;
        }
    }
    out_buf[pos] = '\0';
    return (ssize_t)pos;
}

static void handle_client(int client_fd) {
    char line[MAX_LINE];
    char *env_buf[MAX_ENV + 1];
    int env_count = 0;
    const char *script_name = NULL;

    /* Primeira linha precisa ser RUN <script> */
    ssize_t n = read_line(client_fd, line, sizeof(line));
    if (n <= 0) return;

    if (strncmp(line, "RUN ", 4) != 0) {
        send_line(client_fd, "[DAEMON] Protocolo invalido. Esperado: RUN <script>\n");
        send_line(client_fd, "EXIT:127\n");
        return;
    }

    const char *script_token = line + 4;
    while (*script_token == ' ') script_token++;

    if (strcmp(script_token, "full_memtest") == 0) {
        script_name = "full_memtest.sh";
    } else if (strcmp(script_token, "ram_diagnostic") == 0) {
        script_name = "ram_diagnostic_deep_verbose_root_exec.sh";
    } else {
        char msg[MAX_LINE + 64];
        snprintf(msg, sizeof(msg), "[DAEMON] Script desconhecido: %s\n", script_token);
        send_line(client_fd, msg);
        send_line(client_fd, "EXIT:127\n");
        return;
    }

    /* Le linhas KEY=VALUE ate "END" ou linha vazia */
    while (1) {
        n = read_line(client_fd, line, sizeof(line));
        if (n <= 0) break;
        if (strcmp(line, "END") == 0) break;

        char *eq = strchr(line, '=');
        if (eq == NULL) continue;

        *eq = '\0';
        const char *key = line;
        const char *val = eq + 1;

        if (!key_is_allowed(key)) {
            char msg[MAX_LINE];
            snprintf(msg, sizeof(msg), "[DAEMON] Variavel ignorada (nao permitida): %s\n", key);
            send_line(client_fd, msg);
            continue;
        }
        if (!value_is_safe(val)) {
            char msg[MAX_LINE];
            snprintf(msg, sizeof(msg), "[DAEMON] Variavel ignorada (valor inseguro): %s\n", key);
            send_line(client_fd, msg);
            continue;
        }
        if (env_count >= MAX_ENV) {
            send_line(client_fd, "[DAEMON] Limite de variaveis atingido, ignorando excesso\n");
            break;
        }

        /* Reconstroi "KEY=VALUE" para passar a putenv */
        size_t total = strlen(key) + 1 + strlen(val) + 1;
        char *kv = (char *)malloc(total);
        if (kv == NULL) continue;
        snprintf(kv, total, "%s=%s", key, val);
        env_buf[env_count++] = kv;
    }
    env_buf[env_count] = NULL;

    /* Caminho completo do script */
    char script_path[512];
    snprintf(script_path, sizeof(script_path), "%s/%s", SCRIPT_DIR, script_name);

    /* Checa R_OK (não X_OK): o daemon executa via "/system/bin/sh script",
     * que precisa que o script seja LEGÍVEL — não executável. O prebuilt_etc
     * do AOSP instala scripts como 0644 (sem bit x). */
    if (access(script_path, R_OK) != 0) {
        char msg[600];
        snprintf(msg, sizeof(msg),
                 "[DAEMON] Script nao encontrado ou sem permissao de execucao: %s (%s)\n",
                 script_path, strerror(errno));
        send_line(client_fd, msg);
        send_line(client_fd, "EXIT:127\n");
        for (int i = 0; i < env_count; i++) free(env_buf[i]);
        return;
    }

    char start_msg[700];
    snprintf(start_msg, sizeof(start_msg),
             "[DAEMON] Iniciando %s (%d vars do device aplicadas)\n",
             script_path, env_count);
    send_line(client_fd, start_msg);

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        send_line(client_fd, "[DAEMON] Erro ao criar pipe\n");
        send_line(client_fd, "EXIT:1\n");
        for (int i = 0; i < env_count; i++) free(env_buf[i]);
        return;
    }

    pid_t pid = fork();
    if (pid < 0) {
        send_line(client_fd, "[DAEMON] Erro ao fazer fork\n");
        send_line(client_fd, "EXIT:1\n");
        close(pipefd[0]);
        close(pipefd[1]);
        for (int i = 0; i < env_count; i++) free(env_buf[i]);
        return;
    }

    if (pid == 0) {
        /* Filho: stdout+stderr para o pipe, aplica env vars, exec sh script */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);

        setuid(0);
        setgid(0);

        /* Limpa flags de re-exec dos scripts para nao entrarem em loop */
        unsetenv("ROOT_REEXEC_DONE");
        unsetenv("RAM_DEEP_ALREADY_TRIED_ROOT");

        /* Aplica env vars do device */
        for (int i = 0; i < env_count; i++) {
            putenv(env_buf[i]);
        }

        execl("/system/bin/sh", "sh", script_path, (char *)NULL);
        fprintf(stderr, "[DAEMON] Erro ao executar script: %s\n", strerror(errno));
        _exit(127);
    }

    /* Pai: le do pipe, encaminha pro cliente */
    close(pipefd[1]);

    char buf[BUF_SIZE];
    ssize_t bytes;
    while ((bytes = read(pipefd[0], buf, BUF_SIZE)) > 0) {
        write_all(client_fd, buf, bytes);
    }
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    int exit_code = -1;
    if (WIFEXITED(status)) {
        exit_code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        exit_code = 128 + WTERMSIG(status);
    }

    char exit_msg[32];
    snprintf(exit_msg, sizeof(exit_msg), "EXIT:%d\n", exit_code);
    send_line(client_fd, exit_msg);

    for (int i = 0; i < env_count; i++) {
        /* Nao liberar: putenv guarda o ponteiro. Soltar aqui apos waitpid
         * eh seguro porque o filho ja terminou e o env do pai nao importa
         * mais nesse worker (ele vai exit logo). */
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sa.sa_flags = SA_NOCLDWAIT;
    sigaction(SIGCHLD, &sa, NULL);

    /* Tenta primeiro usar o socket criado pelo init (caminho canonical
     * Android). O init passa o fd via env ANDROID_SOCKET_<name> e cria
     * o socket com a permissao e seclabel certos (do .rc + file_contexts).
     *
     * Se nao houver env (ex: rodando manualmente via shell pra debug),
     * cria o socket nos mesmos moldes — mas faz chmod(0666) explicito
     * pra garantir que apps consigam escrever (caso contrario fica 0700
     * por causa do umask herdado do init). */
    int server_fd = -1;
    {
        char env_key[64];
        snprintf(env_key, sizeof(env_key), "ANDROID_SOCKET_%s", SOCKET_NAME);
        const char *fd_str = getenv(env_key);
        if (fd_str && *fd_str) {
            char *end = NULL;
            long fd = strtol(fd_str, &end, 10);
            if (end != fd_str && fd >= 0 && fd < 1024) {
                server_fd = (int)fd;
                fprintf(stderr, "memtest_daemon: usando socket criado por init (fd=%d)\n", server_fd);
            }
        }
    }

    if (server_fd < 0) {
        fprintf(stderr, "memtest_daemon: env ANDROID_SOCKET_%s nao encontrada — criando socket manualmente\n", SOCKET_NAME);
        server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (server_fd < 0) {
            fprintf(stderr, "memtest_daemon: socket() falhou: %s\n", strerror(errno));
            return 1;
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        snprintf(addr.sun_path, sizeof(addr.sun_path), "/dev/socket/%s", SOCKET_NAME);

        unlink(addr.sun_path);

        if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            fprintf(stderr, "memtest_daemon: bind() falhou: %s\n", strerror(errno));
            close(server_fd);
            return 1;
        }

        /* Forca a permissao certa — sem isso, o socket criado por bind()
         * herda o umask do init (ex: 0077) e fica 0700, impedindo apps
         * de escreverem. */
        if (chmod(addr.sun_path, 0666) < 0) {
            fprintf(stderr, "memtest_daemon: chmod() falhou: %s\n", strerror(errno));
        }
    }

    if (listen(server_fd, 4) < 0) {
        fprintf(stderr, "memtest_daemon: listen() falhou: %s\n", strerror(errno));
        close(server_fd);
        return 1;
    }

    fprintf(stderr, "memtest_daemon: aguardando conexoes em /dev/socket/%s\n", SOCKET_NAME);

    while (1) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "memtest_daemon: accept() falhou: %s\n", strerror(errno));
            continue;
        }

        pid_t worker = fork();
        if (worker == 0) {
            close(server_fd);
            handle_client(client_fd);
            close(client_fd);
            _exit(0);
        }
        close(client_fd);
    }

    close(server_fd);
    return 0;
}
