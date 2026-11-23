/*
 * afalg_bench - drive the kernel crypto API through AF_ALG and measure it.
 *
 *   afalg_bench check        verify AES-256-CBC against a known vector
 *   afalg_bench bench <sec>  measure throughput with 16 KiB buffers
 *
 * Used to compare the EIP197 (safexcel-*) against the ARMv8 crypto
 * extensions (cbc-aes-ce) without any OpenSSL engine in the way.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/socket.h>
#include <linux/if_alg.h>

#ifndef SOL_ALG
#define SOL_ALG 279
#endif

#define BUF 16384
#define KEYLEN 32

static int make_tfm(const char *cipher, const unsigned char *key, int klen)
{
	struct sockaddr_alg sa = {
		.salg_family = AF_ALG,
		.salg_type = "skcipher",
	};
	int tfm;

	strncpy((char *)sa.salg_name, cipher, sizeof(sa.salg_name) - 1);

	tfm = socket(AF_ALG, SOCK_SEQPACKET, 0);
	if (tfm < 0) { perror("socket(AF_ALG)"); return -1; }
	if (bind(tfm, (struct sockaddr *)&sa, sizeof(sa)) < 0) { perror("bind"); close(tfm); return -1; }
	if (setsockopt(tfm, SOL_ALG, ALG_SET_KEY, key, klen) < 0) { perror("ALG_SET_KEY"); close(tfm); return -1; }
	return tfm;
}

static int do_op(int tfm, unsigned char *in, unsigned char *out, int len)
{
	struct msghdr msg = {0};
	struct cmsghdr *cmsg;
	struct af_alg_iv *iv;
	struct iovec iov;
	char cbuf[CMSG_SPACE(4) + CMSG_SPACE(4 + 16)];
	int op = 0, opfd;
	unsigned char ivbuf[16] = {0};
	ssize_t n;

	opfd = accept(tfm, NULL, NULL);
	if (opfd < 0) { perror("accept"); return -1; }

	msg.msg_control = cbuf;
	msg.msg_controllen = sizeof(cbuf);

	cmsg = CMSG_FIRSTHDR(&msg);
	cmsg->cmsg_level = SOL_ALG;
	cmsg->cmsg_type = ALG_SET_OP;
	cmsg->cmsg_len = CMSG_LEN(4);
	memcpy(CMSG_DATA(cmsg), &op, 4);

	cmsg = CMSG_NXTHDR(&msg, cmsg);
	cmsg->cmsg_level = SOL_ALG;
	cmsg->cmsg_type = ALG_SET_IV;
	cmsg->cmsg_len = CMSG_LEN(4 + 16);
	memcpy(CMSG_DATA(cmsg), &(int){16}, 4);
	iv = (struct af_alg_iv *)((char *)CMSG_DATA(cmsg) + 4);
	iv->ivlen = 16;
	memcpy(iv->iv, ivbuf, 16);

	iov.iov_base = in;
	iov.iov_len = len;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;

	n = sendmsg(opfd, &msg, 0);
	if (n < 0) { perror("sendmsg"); close(opfd); return -1; }
	n = read(opfd, out, len);
	close(opfd);
	return (n == len) ? 0 : -1;
}

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	unsigned char key[KEYLEN], iv[16] = {0};
	unsigned char *in = malloc(BUF), *out = malloc(BUF);
	int tfm, i;

	for (i = 0; i < KEYLEN; i++) key[i] = i;
	memset(in, 0x5a, BUF);

	tfm = make_tfm("cbc(aes)", key, KEYLEN);
	if (tfm < 0) return 1;

	if (argc > 1 && !strcmp(argv[1], "dump")) {
		unsigned char p[32];
		memset(p, 0x5a, sizeof(p));
		if (do_op(tfm, p, out, 32)) return 1;
		for (i = 0; i < 32; i++) printf("%02x", out[i]);
		printf("\n");
		return 0;
	}
	if (argc > 1 && !strcmp(argv[1], "check")) {
		/* NIST SP800-38A F.2.5 AES-256-CBC, 4th block */
		unsigned char k[32] = {
			0x60,0x3d,0xeb,0x10,0x15,0xca,0x71,0xbe,0x2b,0x73,0xae,0xf0,0x85,0x7d,0x77,0x81,
			0x1f,0x35,0x2c,0x07,0x3b,0x61,0x08,0xd7,0x2d,0x98,0x10,0xa3,0x09,0x14,0xdf,0xf4 };
		unsigned char p[16] = {
			0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a };
		unsigned char expect[16] = {
			0xf5,0x8c,0x4c,0x04,0xd6,0xe5,0xf1,0xba,0x77,0x9e,0xab,0xfb,0x5f,0x7b,0xfb,0xd6 };
		close(tfm);
		tfm = make_tfm("cbc(aes)", k, 32);
		if (tfm < 0) return 1;
		if (do_op(tfm, p, out, 16)) return 1;
		printf("got     : ");
		for (i = 0; i < 16; i++) printf("%02x", out[i]);
		printf("\nexpect  : ");
		for (i = 0; i < 16; i++) printf("%02x", expect[i]);
		printf("\n%s\n", memcmp(out, expect, 16) ? "MISMATCH" : "OK");
		return 0;
	}

	double secs = argc > 2 ? atof(argv[2]) : 5.0;
	double t0 = now(), t;
	unsigned long iters = 0;
	do {
		if (do_op(tfm, in, out, BUF)) { fprintf(stderr, "op failed\n"); return 1; }
		iters++;
		t = now();
	} while (t - t0 < secs);

	double bytes = (double)iters * BUF;
	printf("%.0f iters in %.2fs -> %.1f MB/s (%.2f Gbps)\n",
	       (double)iters, t - t0, bytes / (t - t0) / 1e6, bytes * 8 / (t - t0) / 1e9);
	return 0;
}
