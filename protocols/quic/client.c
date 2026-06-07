/*
 * protocols/quic/client.c — QUIC + HTTP/3 client (vm1)
 *
 * Completes the QUIC handshake, prints negotiated KEX/cipher/verify, then
 * issues a real HTTP/3 GET / over the connection so a reverse-proxy
 * configuration on the server side (`proxy_pass`) actually forwards
 * traffic to the backend.
 *
 * Output greps consumed by orchestrator/quic.sh stay unchanged:
 *   group: <name>
 *   Cipher is <name>
 *   Verify return code: <n>
 * Additional line:
 *   HTTP/3 status: <n> (body <n> bytes)
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

#include <nghttp3/nghttp3.h>

static void logts(const char *level, const char *msg) {
    time_t t = time(NULL);
    struct tm tm_buf;
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", localtime_r(&t, &tm_buf));
    printf("%s [%s] %s\n", buf, level, msg);
    fflush(stdout);
}

static const unsigned char alpn[] = { 2, 'h', '3' };

/* -------- HTTP/3 stream tracking + nghttp3 callbacks -------- */

#define MAX_H3_STREAMS 64
typedef struct {
    int64_t id;
    SSL    *ssl;
} h3_stream_t;

static h3_stream_t g_streams[MAX_H3_STREAMS];
static int         g_nstreams = 0;

static int    g_h3_status = -1;
static size_t g_h3_body   = 0;
static int    g_h3_done   = 0;
static int64_t g_req_sid  = -1;

static void track(int64_t id, SSL *ssl) {
    if (g_nstreams < MAX_H3_STREAMS) {
        g_streams[g_nstreams].id  = id;
        g_streams[g_nstreams].ssl = ssl;
        g_nstreams++;
    }
}
static SSL *lookup(int64_t id) {
    for (int i = 0; i < g_nstreams; i++)
        if (g_streams[i].id == id) return g_streams[i].ssl;
    return NULL;
}

static int cb_recv_header(nghttp3_conn *c, int64_t sid, int32_t token,
                          nghttp3_rcbuf *name, nghttp3_rcbuf *value, uint8_t flags,
                          void *u1, void *u2) {
    (void)c; (void)token; (void)flags; (void)u1; (void)u2;
    if (sid != g_req_sid) return 0;
    nghttp3_vec n = nghttp3_rcbuf_get_buf(name);
    nghttp3_vec v = nghttp3_rcbuf_get_buf(value);
    if (n.len == 7 && memcmp(n.base, ":status", 7) == 0) {
        char tmp[16] = {0};
        size_t L = v.len < sizeof(tmp) - 1 ? v.len : sizeof(tmp) - 1;
        memcpy(tmp, v.base, L);
        g_h3_status = atoi(tmp);
    }
    return 0;
}
static int cb_recv_data(nghttp3_conn *c, int64_t sid, const uint8_t *data,
                        size_t datalen, void *u1, void *u2) {
    (void)c; (void)data; (void)u1; (void)u2;
    if (sid == g_req_sid) g_h3_body += datalen;
    return 0;
}
static int cb_end_stream(nghttp3_conn *c, int64_t sid, void *u1, void *u2) {
    (void)c; (void)u1; (void)u2;
    if (sid == g_req_sid) g_h3_done = 1;
    return 0;
}
static int cb_stop_sending(nghttp3_conn *c, int64_t sid, uint64_t app_error_code,
                           void *u1, void *u2) {
    (void)c; (void)sid; (void)app_error_code; (void)u1; (void)u2;
    return 0;
}
static int cb_reset_stream(nghttp3_conn *c, int64_t sid, uint64_t app_error_code,
                           void *u1, void *u2) {
    (void)c; (void)sid; (void)app_error_code; (void)u1; (void)u2;
    return 0;
}
static int cb_deferred_consume(nghttp3_conn *c, int64_t sid, size_t consumed,
                               void *u1, void *u2) {
    (void)c; (void)sid; (void)consumed; (void)u1; (void)u2;
    return 0;
}

/* Send HTTP/3 GET on the existing QUIC connection. Returns 0 on success. */
static int h3_get(SSL *conn_ssl, const char *authority, const char *path) {
    SSL_set_blocking_mode(conn_ssl, 0);

    nghttp3_settings settings;
    nghttp3_settings_default(&settings);

    nghttp3_callbacks cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.recv_header      = cb_recv_header;
    cbs.recv_data        = cb_recv_data;
    cbs.end_stream       = cb_end_stream;
    cbs.stop_sending     = cb_stop_sending;
    cbs.reset_stream     = cb_reset_stream;
    cbs.deferred_consume = cb_deferred_consume;

    nghttp3_conn *h3 = NULL;
    if (nghttp3_conn_client_new(&h3, &cbs, &settings, NULL, NULL) != 0) {
        fprintf(stderr, "[ERROR] nghttp3_conn_client_new failed\n");
        return 1;
    }

    SSL *s_ctrl = SSL_new_stream(conn_ssl, SSL_STREAM_FLAG_UNI);
    SSL *s_qenc = SSL_new_stream(conn_ssl, SSL_STREAM_FLAG_UNI);
    SSL *s_qdec = SSL_new_stream(conn_ssl, SSL_STREAM_FLAG_UNI);
    if (!s_ctrl || !s_qenc || !s_qdec) {
        fprintf(stderr, "[ERROR] SSL_new_stream (uni) failed\n");
        nghttp3_conn_del(h3);
        return 1;
    }
    int64_t id_ctrl = SSL_get_stream_id(s_ctrl);
    int64_t id_qenc = SSL_get_stream_id(s_qenc);
    int64_t id_qdec = SSL_get_stream_id(s_qdec);
    track(id_ctrl, s_ctrl);
    track(id_qenc, s_qenc);
    track(id_qdec, s_qdec);

    if (nghttp3_conn_bind_control_stream(h3, id_ctrl) != 0 ||
        nghttp3_conn_bind_qpack_streams(h3, id_qenc, id_qdec) != 0) {
        fprintf(stderr, "[ERROR] nghttp3 bind streams failed\n");
        nghttp3_conn_del(h3);
        return 1;
    }

    SSL *s_req = SSL_new_stream(conn_ssl, 0);
    if (!s_req) {
        fprintf(stderr, "[ERROR] SSL_new_stream (bidi req) failed\n");
        nghttp3_conn_del(h3);
        return 1;
    }
    g_req_sid = SSL_get_stream_id(s_req);
    track(g_req_sid, s_req);

    nghttp3_nv nva[] = {
        {(uint8_t *)":method",    (uint8_t *)"GET",                 7, 3,  NGHTTP3_NV_FLAG_NONE},
        {(uint8_t *)":scheme",    (uint8_t *)"https",               7, 5,  NGHTTP3_NV_FLAG_NONE},
        {(uint8_t *)":authority", (uint8_t *)authority,            10, strlen(authority),
                                                                        NGHTTP3_NV_FLAG_NONE},
        {(uint8_t *)":path",      (uint8_t *)path,                  5, strlen(path),
                                                                        NGHTTP3_NV_FLAG_NONE},
        {(uint8_t *)"user-agent", (uint8_t *)"proto-testbed/1.0",  10, 17, NGHTTP3_NV_FLAG_NONE},
    };
    /* dr=NULL implicitly ends the request stream (no body). */
    if (nghttp3_conn_submit_request(h3, g_req_sid, nva,
                                    sizeof(nva) / sizeof(nva[0]), NULL, NULL) != 0) {
        fprintf(stderr, "[ERROR] nghttp3_conn_submit_request failed\n");
        nghttp3_conn_del(h3);
        return 1;
    }

    time_t deadline = time(NULL) + 6;
    uint8_t rbuf[4096];
    while (!g_h3_done && time(NULL) < deadline) {
        /* producer: drain nghttp3 outgoing into the matching OpenSSL stream */
        for (int n = 0; n < 64; n++) {
            nghttp3_vec vec[16];
            int64_t sid = -1;
            int fin = 0;
            nghttp3_ssize nv = nghttp3_conn_writev_stream(h3, &sid, &fin, vec, 16);
            if (nv <= 0) break;
            SSL *s = lookup(sid);
            if (!s) break;
            size_t total = 0;
            for (nghttp3_ssize i = 0; i < nv; i++) {
                size_t w = 0;
                if (SSL_write_ex(s, vec[i].base, vec[i].len, &w) != 1) break;
                total += w;
            }
            if (total > 0) nghttp3_conn_add_write_offset(h3, sid, total);
            if (fin) SSL_stream_conclude(s, 0);
            if (total == 0) break;
        }

        /* accept server-initiated unidirectional streams */
        SSL *acc;
        while ((acc = SSL_accept_stream(conn_ssl, SSL_ACCEPT_STREAM_NO_BLOCK)) != NULL) {
            int64_t aid = SSL_get_stream_id(acc);
            SSL_set_blocking_mode(acc, 0);
            track(aid, acc);
        }

        /* consumer */
        for (int i = 0; i < g_nstreams && !g_h3_done; i++) {
            size_t nr = 0;
            int rc = SSL_read_ex(g_streams[i].ssl, rbuf, sizeof(rbuf), &nr);
            if (rc == 1 && nr > 0) {
                int fin_recv = SSL_get_stream_read_state(g_streams[i].ssl)
                                   == SSL_STREAM_STATE_FINISHED;
                nghttp3_ssize used = nghttp3_conn_read_stream(
                    h3, g_streams[i].id, rbuf, nr, fin_recv);
                if (used < 0) {
                    fprintf(stderr, "[ERROR] nghttp3_conn_read_stream: %s\n",
                            nghttp3_strerror((int)used));
                    break;
                }
            }
        }

        SSL_handle_events(conn_ssl);
        usleep(20000);
    }

    nghttp3_conn_del(h3);
    return g_h3_done ? 0 : 1;
}

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

    int data_rc = h3_get(ssl, server_ip, "/");
    if (data_rc == 0) {
        printf("HTTP/3 status: %d (body %zu bytes)\n", g_h3_status, g_h3_body);
        fflush(stdout);
    } else {
        fprintf(stderr, "[WARN] HTTP/3 GET did not complete within deadline.\n");
    }

    sleep(1);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    return (int)vrc != 0 ? (int)vrc : data_rc;
}
