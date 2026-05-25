REPO_ROOT := $(shell cd ../.. && pwd)
OSSL_DIR  := $(REPO_ROOT)/os-lib/install/openssl-4.0

CC      = gcc
CFLAGS  = -Wall -Wextra -std=c11 -I$(OSSL_DIR)/include
LDFLAGS = -L$(OSSL_DIR)/lib -lssl -lcrypto -Wl,-rpath,$(OSSL_DIR)/lib

.PHONY: all clean

all: server client

server: server.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

client: client.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f server client
