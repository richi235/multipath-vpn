#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>

#include "dccp.h"

struct tfrc_tx_info {
  uint64_t tfrctx_x;
  uint64_t tfrctx_x_recv;
  uint32_t tfrctx_x_calc;
  uint32_t tfrctx_rtt;
  uint32_t tfrctx_p;
  uint32_t tfrctx_rto;
  uint32_t tfrctx_ipi;
};

uint8_t CCID = 3;

int error_exit(const char *str)
{
	perror(str);
	exit(errno);
}

int main(int argc, char *argv[])
{
	if (argc < 5) {
		printf("Usage: ./client <server address> <port> <service code> " "<message 1> [message 2] ... \n");
		exit(-1);
	}
	struct sockaddr_in server_addr = {
		.sin_family = AF_INET,
		.sin_port = htons(atoi(argv[2])),
	};

	if (!inet_pton(AF_INET, argv[1], &server_addr.sin_addr.s_addr)) {
		printf("Invalid address %s\n", argv[1]);
		exit(-1);
	}

	int socket_fd = socket(AF_INET, SOCK_DCCP, IPPROTO_DCCP);
	if (socket_fd < 0)
		error_exit("socket");

	if (setsockopt(socket_fd, SOL_DCCP, DCCP_SOCKOPT_SERVICE, &(int){htonl(atoi(argv[3]))},
								 sizeof(int)))
		error_exit("setsockopt(DCCP_SOCKOPT_SERVICE)");

        if (setsockopt(socket_fd, SOL_DCCP, DCCP_SOCKOPT_CCID, &CCID, sizeof(CCID)))
          error_exit("setsockopt(ccid)");

	if (connect(socket_fd, (struct sockaddr *)&server_addr, sizeof(server_addr)))
		error_exit("connect");

	// Get the maximum packet size
	uint32_t mps;
	socklen_t res_len = sizeof(mps);
	if (-1 == getsockopt(socket_fd, 269, DCCP_SOCKOPT_GET_CUR_MPS, &mps, &res_len))
		error_exit("getsockopt(DCCP_SOCKOPT_GET_CUR_MPS)");
	printf("Maximum Packet Size: %d\n", mps);
        printf("%d\n", SOL_DCCP);

	for (int i = 4; i < argc; i++) {
		if (send(socket_fd, argv[i], strlen(argv[i]) + 1, 0) < 0)
			error_exit("send");
	}

        struct  tfrc_tx_info dccp_info;
        unsigned int dccp_info_len = sizeof(dccp_info);
        if (-1 == getsockopt(socket_fd, 269, 192, &dccp_info, &dccp_info_len)){
            error_exit("errno after dccp send");
        }

        printf("dccp rtt: %i\n", dccp_info.tfrctx_rtt);
        printf("dccp send_rate: %i\n", dccp_info.tfrctx_x);

	// Wait for a while to allow all the messages to be transmitted
	usleep(5 * 1000);

	close(socket_fd);
	return 0;
}
