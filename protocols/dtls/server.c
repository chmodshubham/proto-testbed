/*
 * protocols/dtls/server.c — DTLS 1.2 server (vm2)
 *
 * Binds a UDP socket, loops accepting DTLS 1.2 connections, logs one line
 * per handshake. Run from repo root; mode = classical only.
 *
 * Build: make -C protocols/dtls
 * Usage: ./protocols/dtls/server classical
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
#include <openssl/rand.h>

#define PORT_ENV "PORT_DTLS"
#define PORT_DEFAULT 4437

static volatile int running = 1;
static int          sock    = -1;
static unsigned char cookie_secret[32];

static void handle_signal(int s) { (void)s; running = 0; if (sock != -1) close(sock); }

static void logts(const char *level, const char *msg) {
    time_t t = time(NULL);
    struct tm tm_buf;
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", localtime_r(&t, &tm_buf));
    printf("%s [%s] %s\n", buf, level, msg);
    fflush(stdout);
}

static int cookie_gen(SSL *ssl, unsigned char *out, unsigned int *outlen) {
    union { struct sockaddr_storage ss; struct sockaddr_in s4; } peer;
    (void)BIO_dgram_get_peer(SSL_get_wbio(ssl), &peer);
    unsigned int plen = sizeof(struct sockaddr_in);
    unsigned char buf[sizeof(peer) + sizeof(cookie_secret)];
    memcpy(buf, &peer, plen);
    memcpy(buf + plen, cookie_secret, sizeof(cookie_secret));
    EVP_Digest(buf, plen + sizeof(cookie_secret), out, outlen, EVP_sha256(), NULL);
    return 1;
}

static int cookie_verify(SSL *ssl, const unsigned char *in, unsigned int inlen) {
    unsigned char expected[32]; unsigned int elen = 32;
    cookie_gen(ssl, expected, &elen);
    return (inlen == elen && memcmp(in, expected, inlen) == 0) ? 1 : 0;
}

int main(int argc, char *argv[]) {
    const char *cafile   = "pki/out/ca/dtls/classical/ca-cert.pem";
    const char *certfile = "pki/out/dtls/classical/server-cert.pem";
    const char *keyfile  = "pki/out/dtls/classical/server-key.pem";
    const char *groups   = "secp521r1:secp384r1";
    const char *ciphers  = "ECDHE-ECDSA-AES256-GCM-SHA384";
    const char *sigalgs  = "ecdsa_secp521r1_sha512";

    if (argc > 1 && strcmp(argv[1], "classical") != 0) {
        fprintf(stderr, "Usage: %s classical\n", argv[0]);
        return 1;
    }

    const char *bind_ip = getenv("VM2_IP");
    if (!bind_ip || bind_ip[0] == '\0') {
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
    snprintf(msg, sizeof(msg), "Listening on:       %s:%d (UDP)", bind_ip, port);
    logts("INFO", msg);
    logts("INFO", "Protocol:           DTLS 1.2");
    snprintf(msg, sizeof(msg), "Server certificate: %s", certfile);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "KEX groups:         %s", groups);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "Cipher suites:      %s", ciphers);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "Signature algs:     %s", sigalgs);
    logts("INFO", msg);
    printf("\n"); fflush(stdout);

    RAND_bytes(cookie_secret, sizeof(cookie_secret));
    signal(SIGINT,  handle_signal);
    signal(SIGTERM, handle_signal);

    SSL_CTX *ctx = SSL_CTX_new(DTLS_server_method());
    if (!ctx) { ERR_print_errors_fp(stderr); return 1; }
    SSL_CTX_set_min_proto_version(ctx, DTLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(ctx, DTLS1_2_VERSION);
    SSL_CTX_set1_groups_list(ctx, groups);
    SSL_CTX_set_cipher_list(ctx, ciphers);
    SSL_CTX_set1_sigalgs_list(ctx, sigalgs);
    SSL_CTX_set_cookie_generate_cb(ctx, cookie_gen);
    SSL_CTX_set_cookie_verify_cb(ctx, cookie_verify);
    if (!SSL_CTX_use_certificate_file(ctx, certfile, SSL_FILETYPE_PEM)) {
        fprintf(stderr, "[ERROR] Failed to load cert: %s\n", certfile);
        SSL_CTX_free(ctx); return 1;
    }
    if (!SSL_CTX_use_PrivateKey_file(ctx, keyfile, SSL_FILETYPE_PEM)) {
        fprintf(stderr, "[ERROR] Failed to load key: %s\n", keyfile);
        SSL_CTX_free(ctx); return 1;
    }
    if (!SSL_CTX_load_verify_locations(ctx, cafile, NULL)) {
        fprintf(stderr, "[ERROR] Failed to load CA: %s\n", cafile);
        SSL_CTX_free(ctx); return 1;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);

    sock = socket(AF_INET, SOCK_DGRAM, 0);
    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons((uint16_t)port);
    addr.sin_addr.s_addr = inet_addr(bind_ip);
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }

    logts("INFO", "Server is ready and accepting connections.");
    printf("\n"); fflush(stdout);

    while (running) {
        struct sockaddr_in peer = {0};
        socklen_t plen = sizeof(peer);
        char peek[1];
        if (recvfrom(sock, peek, 1, MSG_PEEK, (struct sockaddr *)&peer, &plen) < 0) break;

        BIO *bio = BIO_new_dgram(sock, BIO_NOCLOSE);
        BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_PEER, 0, &peer);
        struct timeval tv = {5, 0};
        BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_RECV_TIMEOUT, 0, &tv);

        SSL *ssl = SSL_new(ctx);
        SSL_set_bio(ssl, bio, bio);
        SSL_set_options(ssl, SSL_OP_COOKIE_EXCHANGE);

        if (SSL_accept(ssl) == 1) {
            const SSL_CIPHER *c = SSL_get_current_cipher(ssl);
            const char *ciph    = c ? SSL_CIPHER_get_name(c) : "(NONE)";
            const char *grp     = SSL_get0_group_name(ssl);
            if (!grp || grp[0] == '\0') grp = "unknown";
            snprintf(msg, sizeof(msg),
                     "Handshake OK: KEX=%-20s Cipher=%s", grp, ciph);
            logts("INFO", msg);
            char buf[256];
            int n = SSL_read(ssl, buf, sizeof(buf) - 1);
            if (n > 0) {
                buf[n] = '\0';
                logts("INFO", "Data OK: PING received, sending PONG.");
                SSL_write(ssl, "PONG\n", 5);
            }
            SSL_shutdown(ssl);
        } else {
            ERR_clear_error();
        }
        SSL_free(ssl);
    }

    if (sock != -1) { close(sock); sock = -1; }
    SSL_CTX_free(ctx);
    return 0;
}
