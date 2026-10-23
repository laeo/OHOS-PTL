#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static void dump_fb(int fd, uint32_t fb_id, const char *tag, int ndump, const char *outbase) {
    drmModeFB2 *fb2 = drmModeGetFB2(fd, fb_id);
    drmModeFB *fbo = NULL;
    uint32_t w=0,h=0,pitch=0,fourcc=0,mod_hi=0,mod_lo=0;
    if (fb2) { w=fb2->width; h=fb2->height; pitch=fb2->pitches[0]; fourcc=fb2->pixel_format;
               mod_hi=fb2->modifier>>32; mod_lo=fb2->modifier&0xffffffffu; }
    else { fbo=drmModeGetFB(fd, fb_id); if(!fbo){printf("%s fb %u: getfb fail\n",tag,fb_id);return;} w=fbo->width;h=fbo->height;pitch=fbo->pitch; }
    printf("%s fb=%u %ux%u pitch=%u fourcc=0x%08x mod=0x%08x%08x\n",tag,w?fb_id:0,w,h,pitch,fourcc,mod_hi,mod_lo);
    uint32_t handle = fb2 ? fb2->handles[0] : fbo->handle;
    int dfd=-1;
    if (drmPrimeHandleToFD(fd, handle, DRM_CLOEXEC, &dfd)!=0){printf("  prime fail %s\n",strerror(errno));goto done;}
    if (ndump) {
        size_t size=(size_t)pitch*h;
        void*p=mmap(NULL,size,PROT_READ,MAP_SHARED,dfd,0);
        if(p!=MAP_FAILED){
            char out[256]; snprintf(out,sizeof out,"%s_%u.ppm",outbase,fb_id);
            FILE*f=fopen(out,"wb"); fprintf(f,"P6\n%u %u\n255\n",w,h);
            unsigned char*b=p;
            for(uint32_t y=0;y<h;y++) for(uint32_t x=0;x<w;x++){unsigned char*px=b+(size_t)y*pitch+x*4; fputc(px[0],f);fputc(px[1],f);fputc(px[2],f);}
            fclose(f); printf("  -> %s\n",out);
            munmap(p,size);
        } else printf("  mmap fail %s\n",strerror(errno));
    }
    close(dfd);
done:
    if(fb2)drmModeFreeFB2(fb2);
    if(fbo)drmModeFreeFB(fbo);
}

int main(int argc,char**argv){
    const char *dev="/dev/dri/card0";
    const char *base=argc>1?argv[1]:"/data/local/tmp/drmfb2";
    int fd=open(dev,O_RDWR|O_CLOEXEC); if(fd<0){perror("open");return 1;}
    drmModeRes*res=drmModeGetResources(fd); if(!res){perror("res");return 1;}
    printf("crtcs=%d connectors=%d\n",res->count_crtcs,res->count_connectors);
    for(int i=0;i<res->count_crtcs;i++){
        drmModeCrtc*c=drmModeGetCrtc(fd,res->crtcs[i]);
        if(c){printf("CRTC %u buffer_id=%u mode=%dx%d\n",c->crtc_id,c->buffer_id,c->width,c->height);
              if(c->buffer_id) dump_fb(fd,c->buffer_id,"  crtc-fb",1,base);
              drmModeFreeCrtc(c);}
    }
    drmModePlaneRes*pr=drmModeGetPlaneResources(fd);
    if(pr){printf("planes=%u\n",pr->count_planes);
      for(uint32_t i=0;i<pr->count_planes;i++){
        drmModePlane*p=drmModeGetPlane(fd,pr->planes[i]);
        if(!p)continue;
        printf("PLANE %u crtc=%u fb=%u\n",p->plane_id,p->crtc_id,p->fb_id);
        if(p->fb_id) dump_fb(fd,p->fb_id,"  plane-fb",1,base);
        drmModeFreePlane(p);
      }
      drmModeFreePlaneResources(pr);
    }
    drmModeFreeResources(res); close(fd); return 0;
}
