/*
 * protocols/quic/server.c — QUIC server (vm2)
 *
 * Binds a UDP socket, loops accepting QUIC connections, logs one line
 * per handshake. Run from repo root.
 *
 * Build: make -C protocols/quic
 * Usage: ./protocols/quic/server [classical|pqc]
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/quic.h>

static volatile int running = 1;

static void handle_signal(int s) { (void)s; running = 0; }

static void logts(const char *level, const char *msg) {
    time_t t = time(NULL);
    struct tm tm_buf;
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", localtime_r(&t, &tm_buf));
    printf("%s [%s] %s\n", buf, level, msg);
    fflush(stdout);
}

static const unsigned char alpn[] = { 10, 'h','q','-','i','n','t','e','r','o','p' };

static int alpn_select_cb(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                           const unsigned char *in, unsigned int inlen, void *arg) {
    (void)ssl; (void)arg;
    if (SSL_select_next_proto((unsigned char **)out, outlen,
                              alpn, sizeof(alpn), in, inlen) == OPENSSL_NPN_NEGOTIATED)
        return SSL_TLSEXT_ERR_OK;
    return SSL_TLSEXT_ERR_NOACK;
}

int main(int argc, char *argv[]) {
    int pqc = 0;
    if (argc > 1) {
        if (strcmp(argv[1], "pqc") == 0) {
            pqc = 1;
        } else if (strcmp(argv[1], "classical") != 0) {
            fprintf(stderr, "Usage: %s [classical|pqc]\n", argv[0]);
            return 1;
        }
    }

    const char *certfile, *keyfile, *groups, *ciphers, *sigalgs, *port_env_name;
    int port_default;

    if (pqc) {
        certfile      = "pki/out/quic/pqc/server-cert.pem";
        keyfile       = "pki/out/quic/pqc/server-key.pem";
        groups        = "X25519MLKEM768:X25519:P-256";
        ciphers       = "TLS_AES_128_GCM_SHA256";
        sigalgs       = "mldsa65:mldsa44:ed25519";
        port_env_name = "PORT_QUIC_PQC";
        port_default  = 4439;
    } else {
        certfile      = "pki/out/quic/classical/server-cert.pem";
        keyfile       = "pki/out/quic/classical/server-key.pem";
        groups        = "X25519:P-256";
        ciphers       = "TLS_AES_128_GCM_SHA256";
        sigalgs       = "ed25519:ecdsa_secp256r1_sha256";
        port_env_name = "PORT_QUIC";
        port_default  = 4438;
    }

    const char *bind_ip = getenv("VM2_IP");
    if (!bind_ip || bind_ip[0] == '\0') {
        fprintf(stderr, "[ERROR] VM2_IP not set. Source env.sh from repo root.\n");
        return 1;
    }
    const char *port_str = getenv(port_env_name);
    int port = port_str && port_str[0] ? atoi(port_str) : port_default;
    if (port <= 0 || port > 65535) {
        fprintf(stderr, "[ERROR] Invalid port %d from %s.\n", port, port_env_name);
        return 1;
    }

    char msg[256];
    logts("INFO", pqc ? "Mode:               pqc" : "Mode:               classical");
    snprintf(msg, sizeof(msg), "Listening on:       %s:%d (UDP)", bind_ip, port);
    logts("INFO", msg);
    logts("INFO", "Protocol:           QUIC");
    snprintf(msg, sizeof(msg), "Server certificate: %s", certfile);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "KEX groups:         %s", groups);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "Cipher suites:      %s", ciphers);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "Signature algs:     %s", sigalgs);
    logts("INFO", msg);
    printf("\n"); fflush(stdout);

    signal(SIGINT,  handle_signal);
    signal(SIGTERM, handle_signal);

    SSL_CTX *ctx = SSL_CTX_new(OSSL_QUIC_server_method());
    if (!ctx) { ERR_print_errors_fp(stderr); return 1; }

    if (!SSL_CTX_use_certificate_file(ctx, certfile, SSL_FILETYPE_PEM)) {
        fprintf(stderr, "[ERROR] Failed to load cert: %s\n", certfile);
        SSL_CTX_free(ctx); return 1;
    }
    if (!SSL_CTX_use_PrivateKey_file(ctx, keyfile, SSL_FILETYPE_PEM)) {
        fprintf(stderr, "[ERROR] Failed to load key: %s\n", keyfile);
        SSL_CTX_free(ctx); return 1;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    SSL_CTX_set1_groups_list(ctx, groups);
    SSL_CTX_set_cipher_list(ctx, "");
    SSL_CTX_set_ciphersuites(ctx, ciphers);
    SSL_CTX_set1_sigalgs_list(ctx, sigalgs);
    SSL_CTX_set_alpn_select_cb(ctx, alpn_select_cb, NULL);

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("socket"); SSL_CTX_free(ctx); return 1; }
    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons((uint16_t)port);
    addr.sin_addr.s_addr = inet_addr(bind_ip);
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(sock); SSL_CTX_free(ctx); return 1;
    }

    BIO *bio = BIO_new_dgram(sock, BIO_CLOSE);
    if (!bio) {
        fprintf(stderr, "[ERROR] BIO_new_dgram failed.\n");
        close(sock); SSL_CTX_free(ctx); return 1;
    }

    SSL *listener = SSL_new_listener(ctx, 0);
    if (!listener) {
        fprintf(stderr, "[ERROR] SSL_new_listener failed.\n");
        ERR_print_errors_fp(stderr);
        BIO_free(bio); SSL_CTX_free(ctx); return 1;
    }
    SSL_set_bio(listener, bio, bio);

    if (!SSL_listen(listener)) {
        fprintf(stderr, "[ERROR] SSL_listen failed.\n");
        ERR_print_errors_fp(stderr);
        SSL_free(listener); SSL_CTX_free(ctx); return 1;
    }

    logts("INFO", "Server is ready and accepting connections.");
    printf("\n"); fflush(stdout);

    while (running) {
        SSL *conn = SSL_accept_connection(listener, 0);
        if (!conn) {
            if (!running) break;
            ERR_clear_error();
            continue;
        }

        if (SSL_accept(conn) == 1) {
            const SSL_CIPHER *c = SSL_get_current_cipher(conn);
            const char *ciph    = c ? SSL_CIPHER_get_name(c) : "(NONE)";
            const char *grp     = SSL_get0_group_name(conn);
            if (!grp || grp[0] == '\0') grp = "unknown";
            snprintf(msg, sizeof(msg),
                     "Handshake OK: KEX=%-20s Cipher=%s", grp, ciph);
            logts("INFO", msg);

            char buf[256];
            size_t nread = 0;
            SSL_read_ex(conn, buf, sizeof(buf) - 1, &nread);
            if (nread > 0) {
                snprintf(msg, sizeof(msg), "Data OK: %zu bytes received, sending response.", nread);
                logts("INFO", msg);
                const char *resp = "I am fine, client!\n";
                size_t nwritten = 0;
                SSL_write_ex(conn, resp, strlen(resp), &nwritten);
            }
            SSL_stream_conclude(conn, 0);
            SSL_shutdown(conn);
        } else {
            ERR_clear_error();
        }
        SSL_free(conn);
    }

    SSL_free(listener);
    SSL_CTX_free(ctx);
    return 0;
}
