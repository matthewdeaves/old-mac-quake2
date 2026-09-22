#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_time.h>
#include <stdint.h>
extern void SDL_GL_SwapBuffers(void);
extern void SDL_LockAudio(void);
static double scale;
static unsigned count;
static double audio;
static struct { double start, end, audio; } frames[40000];
static double now(void) { return mach_absolute_time()*scale; }
static void save(void) {
 const char *path=getenv("Q2_TRACE_PATH");
 FILE *f=path?fopen(path,"w"):NULL;
 if(!f)return;
 fprintf(f,"start_ms,end_ms,audio_lock_ms\n");
 for(unsigned i=0;i<count;i++)fprintf(f,"%.6f,%.6f,%.6f\n",frames[i].start,frames[i].end,frames[i].audio);
 fclose(f);
}
__attribute__((constructor)) static void init(void) {
 mach_timebase_info_data_t tb; mach_timebase_info(&tb);
 scale=(double)tb.numer/tb.denom/1000000.; atexit(save);
}
static void swap(void) {
 double t=now(); SDL_GL_SwapBuffers();
 if(count<40000){frames[count].start=t;frames[count].end=now();frames[count++].audio=audio;audio=0;}
 if(count && count%600==0)save();
}
static void lock(void) { double t=now(); SDL_LockAudio(); audio+=now()-t; }
__attribute__((used)) static struct {const void *replacement,*original;} hooks[]
__attribute__((section("__DATA,__interpose")))={{swap,SDL_GL_SwapBuffers},{lock,SDL_LockAudio}};
