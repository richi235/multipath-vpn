#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <linux/sockios.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

int main ()
{
        printf("SOL_DCCP: %i \nSIOCOUTQ: %i\n", SOL_DCCP, SIOCOUTQ);
}
