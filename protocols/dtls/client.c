/*
 * protocols/dtls/client.c — DTLS 1.2 client (vm1)
 *
 * Connects, completes handshake, prints negotiated KEX/cipher/verify, exits.
 * Output format matches what orchestrator/dtls.sh greps for:
 *   group: <name>
 *   Cipher is <name>
 *   Verify return code: <n>
 *
 * Build: make -C protocols/dtls
 * Usage: ./protocols/dtls/client classical
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

#define PORT_ENV     "PORT_DTLS"
#define PORT_DEFAULT 4437

static void logts(const char *level, const char *msg) {
    time_t t = time(NULL);
    struct tm tm_buf;
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", localtime_r(&t, &tm_buf));
    printf("%s [%s] %s\n", buf, level, msg);
    fflush(stdout);
}

int main(int argc, char *argv[]) {
    const char *cafile  = "pki/out/ca/dtls/classical/ca-cert.pem";
    const char *groups  = "secp521r1:secp384r1";
    const char *ciphers = "ECDHE-ECDSA-AES256-GCM-SHA384";
    const char *sigalgs = "ecdsa_secp521r1_sha512";

    if (argc > 1 && strcmp(argv[1], "classical") != 0) {
        fprintf(stderr, "Usage: %s classical\n", argv[0]); return 1;
    }

    const char *server_ip = getenv("VM2_IP");
    if (!server_ip || server_ip[0] == '\0') {
        fprintf(stderr, "[ERROR] VM2_IP not set. Source env.sh from repo root.\n");
        return 1;
    }
    const char *port_env = getenv(PORT_ENV);
    int port = port_env && port_env[0] ? atoi(port_env) : PORT_DEFAULT;
    if (port <= 0 || port > 65535) {
        fprintf(stderr, "[ERROR] Invalid port %d from %s.\n", port, PORT_ENV);
        return 1;
    }

    char msg[256];
    logts("INFO", "Mode:               classical");
    snprintf(msg, sizeof(msg), "Server address:     %s:%d (UDP)", server_ip, port);
    logts("INFO", msg);
    logts("INFO", "Protocol:           DTLS 1.2");
    snprintf(msg, sizeof(msg), "CA certificate:     %s", cafile);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "KEX groups:         %s", groups);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "Cipher suites:      %s", ciphers);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "Signature algs:     %s", sigalgs);
    logts("INFO", msg);
    printf("\n"); fflush(stdout);

    SSL_CTX *ctx = SSL_CTX_new(DTLS_client_method());
    if (!ctx) { ERR_print_errors_fp(stderr); return 1; }
    SSL_CTX_set_min_proto_version(ctx, DTLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(ctx, DTLS1_2_VERSION);
    SSL_CTX_set1_groups_list(ctx, groups);
    SSL_CTX_set_cipher_list(ctx, ciphers);
    SSL_CTX_set1_sigalgs_list(ctx, sigalgs);
    if (!SSL_CTX_load_verify_locations(ctx, cafile, NULL)) {
        fprintf(stderr, "[ERROR] Failed to load CA: %s\n", cafile);
        SSL_CTX_free(ctx); return 1;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in srv = {0};
    srv.sin_family      = AF_INET;
    srv.sin_port        = htons((uint16_t)port);
    srv.sin_addr.s_addr = inet_addr(server_ip);
    if (connect(fd, (struct sockaddr *)&srv, sizeof(srv)) < 0) {
        perror("connect"); SSL_CTX_free(ctx); return 1;
    }

    BIO *bio = BIO_new_dgram(fd, BIO_CLOSE);
    BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, &srv);
    struct timeval tv = {5, 0};
    BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_RECV_TIMEOUT, 0, &tv);

    SSL *ssl = SSL_new(ctx);
    SSL_set_bio(ssl, bio, bio);

    if (SSL_connect(ssl) != 1) {
        ERR_print_errors_fp(stderr);
        SSL_free(ssl); SSL_CTX_free(ctx); return 1;
    }

    long vrc        = SSL_get_verify_result(ssl);
    const char *ciph = SSL_CIPHER_get_name(SSL_get_current_cipher(ssl));
    const char *grp  = SSL_get0_group_name(ssl);
    if (!grp || grp[0] == '\0') grp = "unknown";

    printf("group: %s\n", grp);
    printf("Cipher is %s\n", ciph);
    printf("Verify return code: %ld\n", vrc);
    fflush(stdout);

    int data_rc = 0;
    const char *question = "How are you, server?\n";
    if (SSL_write(ssl, question, (int)strlen(question)) != (int)strlen(question)) {
        fprintf(stderr, "[ERROR] Failed to send question.\n");
        data_rc = 1;
    } else {
        char buf[256];
        int n = SSL_read(ssl, buf, sizeof(buf) - 1);
        if (n <= 0) {
            fprintf(stderr, "[ERROR] No response from server.\n");
            data_rc = 1;
        } else {
            buf[n] = '\0';
            if (strncmp(buf, "I am fine, client!", 18) != 0) {
                fprintf(stderr, "[ERROR] Unexpected response: %s\n", buf);
                data_rc = 1;
            }
        }
    }

    sleep(2);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    return (int)vrc != 0 ? (int)vrc : data_rc;
}
