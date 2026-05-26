/*
 * protocols/quic/client.c — QUIC client (vm1)
 *
 * Connects, completes handshake, prints negotiated KEX/cipher/verify, exits.
 * Output format matches what orchestrator/quic.sh greps for:
 *   group: <name>
 *   Cipher is <name>
 *   Verify return code: <n>
 *
 * Build: make -C protocols/quic
 * Usage: ./protocols/quic/client [classical|pqc]
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
#include <openssl/quic.h>
#include <openssl/bio.h>

static void logts(const char *level, const char *msg) {
    time_t t = time(NULL);
    struct tm tm_buf;
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", localtime_r(&t, &tm_buf));
    printf("%s [%s] %s\n", buf, level, msg);
    fflush(stdout);
}

static const unsigned char alpn[] = { 10, 'h','q','-','i','n','t','e','r','o','p' };

int main(int argc, char *argv[]) {
    int pqc = 0;
    if (argc > 1) {
        if (strcmp(argv[1], "pqc") == 0) {
            pqc = 1;
        } else if (strcmp(argv[1], "classical") != 0) {
            fprintf(stderr, "Usage: %s [classical|pqc]\n", argv[0]); return 1;
        }
    }

    const char *cafile, *groups, *ciphers, *sigalgs, *port_env_name;
    int port_default;

    if (pqc) {
        cafile        = "pki/out/ca/quic/pqc/ca-cert.pem";
        groups        = "X25519MLKEM768:X25519:P-256";
        ciphers       = "TLS_AES_128_GCM_SHA256";
        sigalgs       = "mldsa65:mldsa44:ed25519";
        port_env_name = "PORT_QUIC_PQC";
        port_default  = 4439;
    } else {
        cafile        = "pki/out/ca/quic/classical/ca-cert.pem";
        groups        = "X25519:P-256";
        ciphers       = "TLS_AES_128_GCM_SHA256";
        sigalgs       = "ed25519:ecdsa_secp256r1_sha256";
        port_env_name = "PORT_QUIC";
        port_default  = 4438;
    }

    const char *server_ip = getenv("VM2_IP");
    if (!server_ip || server_ip[0] == '\0') {
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
    snprintf(msg, sizeof(msg), "Server address:     %s:%d (UDP)", server_ip, port);
    logts("INFO", msg);
    logts("INFO", "Protocol:           QUIC");
    snprintf(msg, sizeof(msg), "CA certificate:     %s", cafile);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "KEX groups:         %s", groups);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "Cipher suites:      %s", ciphers);
    logts("INFO", msg);
    snprintf(msg, sizeof(msg), "Signature algs:     %s", sigalgs);
    logts("INFO", msg);
    printf("\n"); fflush(stdout);

    SSL_CTX *ctx = SSL_CTX_new(OSSL_QUIC_client_method());
    if (!ctx) { ERR_print_errors_fp(stderr); return 1; }

    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    if (!SSL_CTX_load_verify_locations(ctx, cafile, NULL)) {
        fprintf(stderr, "[ERROR] Failed to load CA: %s\n", cafile);
        SSL_CTX_free(ctx); return 1;
    }
    SSL_CTX_set1_groups_list(ctx, groups);
    SSL_CTX_set_ciphersuites(ctx, ciphers);
    SSL_CTX_set1_sigalgs_list(ctx, sigalgs);

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); SSL_CTX_free(ctx); return 1; }

    struct sockaddr_in srv = {0};
    srv.sin_family      = AF_INET;
    srv.sin_port        = htons((uint16_t)port);
    srv.sin_addr.s_addr = inet_addr(server_ip);
    if (connect(fd, (struct sockaddr *)&srv, sizeof(srv)) < 0) {
        perror("connect"); close(fd); SSL_CTX_free(ctx); return 1;
    }

    BIO *bio = BIO_new_dgram(fd, BIO_CLOSE);
    if (!bio) {
        fprintf(stderr, "[ERROR] BIO_new_dgram failed.\n");
        close(fd); SSL_CTX_free(ctx); return 1;
    }

    SSL *ssl = SSL_new(ctx);
    if (!ssl) {
        ERR_print_errors_fp(stderr);
        BIO_free(bio); SSL_CTX_free(ctx); return 1;
    }
    SSL_set_bio(ssl, bio, bio);
    SSL_set_tlsext_host_name(ssl, server_ip);
    SSL_set_alpn_protos(ssl, alpn, sizeof(alpn));

    BIO_ADDR *peer_addr = BIO_ADDR_new();
    if (!peer_addr) {
        fprintf(stderr, "[ERROR] BIO_ADDR_new failed.\n");
        SSL_free(ssl); SSL_CTX_free(ctx); return 1;
    }
    BIO_ADDR_rawmake(peer_addr, AF_INET, &srv.sin_addr, sizeof(srv.sin_addr), (unsigned short)port);
    SSL_set1_initial_peer_addr(ssl, peer_addr);
    BIO_ADDR_free(peer_addr);

    if (SSL_connect(ssl) != 1) {
        ERR_print_errors_fp(stderr);
        SSL_free(ssl); SSL_CTX_free(ctx); return 1;
    }

    long vrc             = SSL_get_verify_result(ssl);
    const SSL_CIPHER *c  = SSL_get_current_cipher(ssl);
    const char *ciph     = c ? SSL_CIPHER_get_name(c) : "(NONE)";
    const char *grp      = SSL_get0_group_name(ssl);
    if (!grp || grp[0] == '\0') grp = "unknown";

    printf("group: %s\n", grp);
    printf("Cipher is %s\n", ciph);
    printf("Verify return code: %ld\n", vrc);
    fflush(stdout);

    int data_rc = 0;
    size_t nwritten = 0;
    if (!SSL_write_ex(ssl, "GET / HTTP/1.0\r\n\r\n", 18, &nwritten)) {
        fprintf(stderr, "[ERROR] Failed to send request.\n");
        data_rc = 1;
    } else {
        char buf[256];
        size_t nread = 0;
        if (!SSL_read_ex(ssl, buf, sizeof(buf) - 1, &nread) || nread == 0) {
            fprintf(stderr, "[ERROR] No response from server.\n");
            data_rc = 1;
        }
    }
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    return (int)vrc != 0 ? (int)vrc : data_rc;
}
