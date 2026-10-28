// Synthetic parent process for the stable Keychain component regression.
#include <unistd.h>
#include <sys/wait.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char**argv){
    if(argc!=5)return 2;
    int in[2],out[2];if(pipe(in)||pipe(out))return 2;
    pid_t child=fork();if(child<0)return 2;
    if(!child){dup2(in[0],0);dup2(out[1],1);close(in[0]);close(in[1]);close(out[0]);close(out[1]);execl(argv[1],argv[1],argv[2],argv[3],NULL);_exit(127);}
    close(in[0]);close(out[1]);
    const char *fixture="synthetic-only-not-a-device-credential";
    if(strcmp(argv[2],"store")==0){const char*p=strcmp(argv[4],"mismatch")==0?"different-fixture":fixture;if(write(in[1],p,strlen(p))<0)return 2;}
    close(in[1]);char bytes[256];size_t count=0;ssize_t n;
    while(count<sizeof(bytes)&&(n=read(out[0],bytes+count,sizeof(bytes)-count))>0)count+=n;
    close(out[0]);int status;if(waitpid(child,&status,0)<0)return 2;
    int matches=count==strlen(fixture)&&memcmp(bytes,fixture,count)==0;
    printf("status=%d matches_fixture=%d\n",WIFEXITED(status)?WEXITSTATUS(status):255,matches);
    return 0;
}
