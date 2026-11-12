//HolyCraft: walk a world of blocks, break them and place new ones.
//W S A D walk, the mouse or J L I K look, Space jumps, G flies, R F rise
//and sink, left click breaks, right click places, 1 to 9 and Q E pick a
//block, Esc quits.
//
//Two builds. In the browser (HolyC-wasm) a ray a pixel draws the frame,
//blitted with GrSprite. In TempleOS (Run.HC defines TOS_NATIVE) DrawIt
//fills exposed faces with subpixel spans over a depth buffer.
#ifdef TOS_NATIVE
#define RDIST		32.0	//Render distance, cells.
#define FOG0		20.0	//Fog starts here and is all sky at RDIST.
#define NEAR		0.05	//The box keeps the eye 0.2 from a block.
#define ZFAR		1073741824.0 //Depth far away, 1<<30.
#define SKY_LVS		32	//Dither steps between two sky colors.
#define SKY_ROW		1088	//A sky row: 1024 pixels and 64 of random start.
#else
#define RES_W		640
#define RES_H		480
#define SCALE		1
#define RDIST		48.0
#define FOG0		32.0
#endif
#define FOV		1.05	//Half the view's height at distance 1.
#define SKY_K		2.0	//Sky ramp steps a unit of elevation sine.
#define WX	128
#define WZ	128
#define WY	40
#define WATER	5
#define EYE		1.62	//Eye above the feet.
#define PLAYER_R	0.3	//Half the width of the player's box.
#define PLAYER_TOP	0.2	//Top of the box above the eye.
#define BOX_EPS		0.001	//Shrinks the box, so touching is not hitting.
#define TICK		(1.0/60)	//Physics step, seconds.
#define WALK_SPD	4.8	//Cells a second.
#define FLY_SPD		4.8
#define TURN_SPD	2.1	//Radians a second, J L I K.
#define MS_TURN		0.003	//Radians a mouse step.
#define PITCH_MAX	1.45
#define GRAV		45.0	//Cells a second squared.
#define JUMP_V		13.4	//Clears one block.
#define FALL_MAX	21.0

U8 *g_world=NULL,*g_fb=NULL,*g_hm=NULL,*g_lo=NULL;
U8 g_skyr[3],g_lr[24*4],g_flo[24*6],g_fhi[24*6];
I64 g_fthr[24*6]; //Probability of the brighter face color, 0 to 65535.
I64 g_frame=0,g_sel=8,g_plb=0,g_prb=0;
F64 g_px,g_py,g_pz,g_yaw,g_pitch;
//The page supplies held keys and relative mouse motion to the browser build.
I64 BrowserMouseCapture=0,BrowserMouseDX=0,BrowserMouseDY=0;
U8 BrowserKeys[128];
I64 g_tf,g_tb,g_tl,g_tr,g_tu,g_td,g_tjl,g_tjr,g_tpu,g_tpd;
F64 g_vy=0.0,g_tick_t;
I64 g_fly=0,g_onground=0,g_quit=0;
I64 g_ylo,g_yhi; //Bounds of blocks with exposed faces.
#ifdef TOS_NATIVE
I32 *g_depth=NULL; //A pixel's depth, ZFAR-g_zk/forward: linear on the screen.
I64 g_depthcap=0,g_sw,g_sh,g_edgecap=0,*g_left=NULL,*g_right=NULL;
F64 g_focal,g_cxc,g_cyc,g_zk;
CDC *g_rdc=NULL,*g_view=NULL;
U8 *g_skyrows=NULL; //Dithered rows between two sky colors, SKY_LVS+1 a pair.
U8 *g_win; //The view's top left pixel in the DC's body, g_sw by g_sh.
//Held keys are polled from kbd.down_bitmap, so a lost key up can't leave
//the player walking. Their scan codes are looked up once: Char2ScanCode is
//slow.
I64 g_scw,g_scs,g_sca,g_scd,g_scr,g_scf,g_scj,g_scl,g_sci,g_sck;
#endif

I64 WIdx(I64 x,I64 y,I64 z)
{
  return x+WX*(z+WZ*y);
}

I64 Solid(I64 x,I64 y,I64 z)
{
  if (x<0 || x>=WX || z<0 || z>=WZ || y<0 || y>=WY) return 0;
  return g_world[WIdx(x,y,z)];
}

I64 HeightAt(I64 x,I64 z)
{
  F64 h=14.0+4.0*Sin(x*0.16)+4.0*Cos(z*0.15)+
	2.5*Sin((x+z)*0.08)+2.0*Cos((x-z)*0.11);
  I64 hi=h;
  if (hi<2) hi=2;
  if (hi>WY-8) hi=WY-8;
  return hi;
}

U8 g_materials[8*4]={
  0,0,0,0,
  0,2,10,10, //Grass.
  0,6,6,14, //Dirt.
  0,8,7,15, //Stone.
  0,6,6,14, //Wood.
  0,2,10,10, //Leaves.
  6,14,14,15, //Sand.
  1,9,11,11}; //Water.
U8 g_darker[16]={0,0,0,1,0,0,0,8,0,1,2,9,4,5,6,7},
	g_lighter[16]={8,9,10,11,12,13,14,15,7,11,15,15,14,15,15,15};

U0 SetRamp()
{//Terrain ramps, then the 16 distinct palette colors in the hotbar.
  I64 c;
  g_skyr[0]=BLUE; g_skyr[1]=LTBLUE; g_skyr[2]=LTCYAN;
  MemCpy(g_lr,g_materials,sizeof(g_materials));
  for (c=0;c<16;c++) {
    g_lr[(8+c)*4]=g_darker[c];
    g_lr[(8+c)*4+1]=c;
    g_lr[(8+c)*4+2]=c;
    g_lr[(8+c)*4+3]=g_lighter[c];
  }
}

U0 BuildFaceShades()
{//Fixed light on faces -X,+X,-Y,+Y,-Z,+Z; dither between ramp colors.
  I64 f,bt,lo;
  F64 lx=0.394,ly=0.788,lz=0.473,amb=0.30,d,p,fr;
  for (f=0;f<6;f++) {
    switch (f) {
      case 0: d=-lx; break;
      case 1: d=lx; break;
      case 2: d=-ly; break;
      case 3: d=ly; break;
      case 4: d=-lz; break;
      case 5: d=lz; break;
    }
    p=(amb+(1.0-amb)*Max(d,0.0))*3.0;
    lo=MinI64(p,2);
    fr=Clamp(p-lo,0.0,1.0);
    for (bt=1;bt<=23;bt++) {
      g_flo[bt*6+f]=g_lr[bt*4+lo];
      g_fhi[bt*6+f]=g_lr[bt*4+lo+1];
      g_fthr[bt*6+f]=MinI64(fr*65536.0,65535);
    }
  }
}

U0 PlantTree(I64 x,I64 top,I64 z)
{
  I64 dy,lx,ly,lz;
  for (dy=0; dy<4; dy++)
    if (top+dy<WY) g_world[WIdx(x,top+dy,z)]=4;
  for (ly=top+3; ly<=top+5; ly++)
    for (lx=x-2; lx<=x+2; lx++)
      for (lz=z-2; lz<=z+2; lz++)
	if (!Solid(lx,ly,lz))
	  if ((lx-x)*(lx-x)+(lz-z)*(lz-z)+(ly-top-4)*(ly-top-4)<=6)
	    if (lx>=0 && lx<WX && lz>=0 && lz<WZ && ly<WY)
	      g_world[WIdx(lx,ly,lz)]=5;
}

U0 GenWorld()
{
  I64 x,z,y,h,b;
  for (x=0; x<WX; x++)
    for (z=0; z<WZ; z++) {
      h=HeightAt(x,z);
      for (y=0; y<WY; y++) {
	b=0;
	if (y<h-3)	b=3;	    //stone
	else if (y<h-1) b=2;	    //dirt
	else if (y<h)	b=1;	    //grass (top)
	if (b==0 && y<=WATER && y>=h) b=7;   //water above low terrain
	if (b==1 && h<=WATER+1) b=6;	      //sand at the shoreline
	g_world[WIdx(x,y,z)]=b;
      }
      if (h>WATER+1 && (x*7+z*13)%53==0) PlantTree(x,h,z);
    }
}

Bool CellOpen(U8 *w,I64 x,I64 y,I64 z)
{//Is the block at w, cell x,y,z, there with a face on air in the world?
  if (!*w) return FALSE;
  if (y==WY-1 || !w[WX*WZ]) return TRUE;
  if (y && !w[-WX*WZ]) return TRUE;
  if (x && !w[-1]) return TRUE;
  if (x<WX-1 && !w[1]) return TRUE;
  if (z && !w[-WX]) return TRUE;
  if (z<WZ-1 && !w[WX]) return TRUE;
  return FALSE;
}

U0 ColTop(I64 x,I64 z)
{//A column's top block, and its lowest block with a face on air.
  I64 top=WY-1,lo=0,c=x+WX*z;
  while (top>=0 && !g_world[c+WX*WZ*top])
    top--;
  if (top<0) {
    g_hm[c]=0;
    g_lo[c]=1;
  } else {
    while (lo<top && !CellOpen(g_world+c+WX*WZ*lo,x,lo,z))
      lo++;
    g_hm[c]=top;
    g_lo[c]=lo;
    if (lo<g_ylo) g_ylo=lo;
    if (top>=g_yhi) g_yhi=top+1;
  }
}

U0 ColsTop(I64 x,I64 z)
{//After a block changes in column x,z: it and the four beside it.
  ColTop(x,z);
  if (x) ColTop(x-1,z);
  if (x<WX-1) ColTop(x+1,z);
  if (z) ColTop(x,z-1);
  if (z<WZ-1) ColTop(x,z+1);
}

U0 BuildHM()
{
  I64 x,z;
  g_ylo=WY;
  g_yhi=0;
  for (x=0;x<WX;x++)
    for (z=0;z<WZ;z++)
      ColTop(x,z);
}

U0 Init()
{
  g_quit=FALSE; g_plb=0; g_prb=0; g_frame=0; g_sel=8;
  BrowserMouseDX=0; BrowserMouseDY=0;
  g_tf=0; g_tb=0; g_tl=0; g_tr=0; g_tu=0; g_td=0;
  g_tjl=0; g_tjr=0; g_tpu=0; g_tpd=0;
  g_world=MAlloc(WX*WZ*WY);
  g_hm=MAlloc(WX*WZ);
  g_lo=MAlloc(WX*WZ);
#ifndef TOS_NATIVE
  g_fb=MAlloc(RES_W*RES_H);
#endif
  SetRamp;
  BuildFaceShades;
  GenWorld;
  BuildHM;
  g_px=WX/2+0.5;
  g_pz=WZ/2+0.5;
  g_py=g_hm[WX/2+WX*(WZ/2)]+1+EYE;
  g_vy=0.0;
  g_fly=0;
  g_onground=TRUE;
  g_yaw=0.7;
  g_pitch=-0.06;
  g_tick_t=tS;
}

F64 g_fwx,g_fwy,g_fwz,g_rgx,g_rgz,g_upx,g_upy,g_upz,g_cox,g_coy,g_coz;
I64 g_bix,g_biy,g_biz;

U0 SetupCam()
{//One frame's eye and view: forward, right (no y) and up.
  F64 cp=Cos(g_pitch),sp=Sin(g_pitch),cy=Cos(g_yaw),sy=Sin(g_yaw);
  g_cox=g_px; g_coy=g_py; g_coz=g_pz;
  g_fwx=sy*cp; g_fwy=sp; g_fwz=cy*cp;
  g_rgx=cy; g_rgz=-sy;
  g_upx=-sy*sp; g_upy=cp; g_upz=-cy*sp;
  g_bix=Floor(g_cox); g_biy=Floor(g_coy); g_biz=Floor(g_coz);
}

I64 g_hx,g_hy,g_hz,g_bx,g_by,g_bz;

I64 PickTarget()
{//The first block within six cells, and the empty cell before it.
  F64 cp=Cos(g_pitch),sp=Sin(g_pitch),cy=Cos(g_yaw),sy=Sin(g_yaw),
	dx=sy*cp,dy=sp,dz=cy*cp,ox=g_px,oy=g_py,oz=g_pz,
	tdx,tdy,tdz,tmx,tmy,tmz,t=0.0;
  I64 ix=Floor(ox),iy=Floor(oy),iz=Floor(oz),px,py,pz,stx,sty,stz;
  if (dx>0.0) {
    stx=1; tdx=1.0/dx; tmx=(ix+1-ox)*tdx;
  } else if (dx<0.0) {
    stx=-1; tdx=-1.0/dx; tmx=(ox-ix)*tdx;
  } else {
    stx=0; tdx=1000000.0; tmx=1000000.0;
  }
  if (dy>0.0) {
    sty=1; tdy=1.0/dy; tmy=(iy+1-oy)*tdy;
  } else if (dy<0.0) {
    sty=-1; tdy=-1.0/dy; tmy=(oy-iy)*tdy;
  } else {
    sty=0; tdy=1000000.0; tmy=1000000.0;
  }
  if (dz>0.0) {
    stz=1; tdz=1.0/dz; tmz=(iz+1-oz)*tdz;
  } else if (dz<0.0) {
    stz=-1; tdz=-1.0/dz; tmz=(oz-iz)*tdz;
  } else {
    stz=0; tdz=1000000.0; tmz=1000000.0;
  }
  while (TRUE) {
    px=ix; py=iy; pz=iz;
    if (tmx<tmy && tmx<tmz) {
      ix+=stx; t=tmx; tmx+=tdx;
    } else if (tmy<tmz) {
      iy+=sty; t=tmy; tmy+=tdy;
    } else {
      iz+=stz; t=tmz; tmz+=tdz;
    }
    if (t>6.0) return FALSE;
    if (Solid(ix,iy,iz)) {
      g_hx=ix; g_hy=iy; g_hz=iz;
      g_bx=px; g_by=py; g_bz=pz;
      return TRUE;
    }
  }
}

Bool PlayerHit(F64 x,F64 y,F64 z)
{//Does the player's box, eye at x,y,z, meet a block or leave the world?
  I64 i,j,k,x0=Floor(x-PLAYER_R+BOX_EPS),x1=Floor(x+PLAYER_R-BOX_EPS),
	y0=Floor(y-EYE+BOX_EPS),y1=Floor(y+PLAYER_TOP-BOX_EPS),
	z0=Floor(z-PLAYER_R+BOX_EPS),z1=Floor(z+PLAYER_R-BOX_EPS);
  if (x0<0 || y0<0 || z0<0 || x1>=WX || y1>=WY || z1>=WZ)
    return TRUE;
  for (j=y0;j<=y1;j++)
    for (k=z0;k<=z1;k++)
      for (i=x0;i<=x1;i++)
	if (g_world[i+WX*(k+WZ*j)])
	  return TRUE;
  return FALSE;
}

Bool PlayerMove(I64 axis,F64 d)
{//Moves the eye d along axis 0=x 1=y 2=z. A wall stops the box touching it.
  F64 x=g_px,y=g_py,z=g_pz;
  if (!axis)
    x+=d;
  else if (axis==1)
    y+=d;
  else
    z+=d;
  if (!PlayerHit(x,y,z)) {
    g_px=x; g_py=y; g_pz=z;
    return TRUE;
  }
  if (!axis) {
    if (d>0)
      g_px=Floor(g_px+PLAYER_R-BOX_EPS)+1-PLAYER_R;
    else
      g_px=Floor(g_px-PLAYER_R+BOX_EPS)+PLAYER_R;
  } else if (axis==1) {
    if (d>0)
      g_py=Floor(g_py+PLAYER_TOP-BOX_EPS)+1-PLAYER_TOP;
    else
      g_py=Floor(g_py-EYE+BOX_EPS)+EYE;
  } else if (d>0)
    g_pz=Floor(g_pz+PLAYER_R-BOX_EPS)+1-PLAYER_R;
  else
    g_pz=Floor(g_pz-PLAYER_R+BOX_EPS)+PLAYER_R;
  return FALSE;
}

U0 PlayerTick()
{//One TICK of turning, walking, flying or falling.
  F64 cy,sy,mvx=0.0,mvz=0.0;
  if (g_tjl) g_yaw-=TURN_SPD*TICK;
  if (g_tjr) g_yaw+=TURN_SPD*TICK;
  if (g_tpu) g_pitch+=TURN_SPD*TICK;
  if (g_tpd) g_pitch-=TURN_SPD*TICK;
  g_pitch=Clamp(g_pitch,-PITCH_MAX,PITCH_MAX);
  cy=Cos(g_yaw);
  sy=Sin(g_yaw);
  if (g_tf) {mvx+=sy; mvz+=cy;}
  if (g_tb) {mvx-=sy; mvz-=cy;}
  if (g_tl) {mvx-=cy; mvz+=sy;}
  if (g_tr) {mvx+=cy; mvz-=sy;}
  if (mvx) PlayerMove(0,mvx*WALK_SPD*TICK);
  if (mvz) PlayerMove(2,mvz*WALK_SPD*TICK);
  if (g_fly) {
    if (g_tu) PlayerMove(1,FLY_SPD*TICK);
    if (g_td) PlayerMove(1,-FLY_SPD*TICK);
    g_vy=0.0;
    g_onground=FALSE;
  } else {
    g_vy=Max(g_vy-GRAV*TICK,-FALL_MAX);
    g_onground=FALSE;
    if (!PlayerMove(1,g_vy*TICK)) {
      if (g_vy<0) g_onground=TRUE;
      g_vy=0.0;
    }
  }
}

U0 KeyDown(I64 ch)
{//A key press: jump, fly, pick a block or quit.
  if (ch==' ') {
    if (g_onground && !g_fly) {
      g_vy=JUMP_V;
      g_onground=FALSE;
    }
  } else if (ch=='g') {
    g_fly=!g_fly;
    g_vy=0.0;
  } else if ('1'<=ch<='9')
    g_sel=7+ch-'0';
  else if (ch=='q') {
    if (--g_sel<8) g_sel=23;
  } else if (ch=='e') {
    if (++g_sel>23) g_sel=8;
  } else if (ch==CH_ESC || ch==CH_SHIFT_ESC)
    g_quit=TRUE;
}

#ifdef TOS_NATIVE
U0 InputRead()
{//Presses from messages, held keys from the key bitmap, look from the mouse.
  I64 arg1,arg2,msg;
  while (msg=ScanMsg(&arg1,&arg2,1<<MSG_KEY_DOWN|1<<MSG_KEY_UP))
    if (msg==MSG_KEY_DOWN) {
      if (arg1)
	KeyDown(arg1);
      else
	switch (arg2.u8[0]) {
	  case SC_CURSOR_LEFT:
	  case SC_CURSOR_UP:
	    if (--g_sel<8) g_sel=23;
	    break;
	  case SC_CURSOR_RIGHT:
	  case SC_CURSOR_DOWN:
	    if (++g_sel>23) g_sel=8;
	    break;
	}
    }
  g_tf=Bt(kbd.down_bitmap,g_scw);
  g_tb=Bt(kbd.down_bitmap,g_scs);
  g_tl=Bt(kbd.down_bitmap,g_sca);
  g_tr=Bt(kbd.down_bitmap,g_scd);
  g_tjl=Bt(kbd.down_bitmap,g_scj);
  g_tjr=Bt(kbd.down_bitmap,g_scl);
  g_tpu=Bt(kbd.down_bitmap,g_sci);
  g_tpd=Bt(kbd.down_bitmap,g_sck);
  g_tu=Bt(kbd.down_bitmap,g_scr);
  g_td=Bt(kbd.down_bitmap,g_scf);
  g_yaw+=(ms.pos.x-320)*MS_TURN;
  g_pitch-=(ms.pos.y-240)*MS_TURN;
  MsSet(320,240);
}
#else
U0 InputRead()
{//Presses from the char queue, held keys and look from the page.
  while (ScanChar)
    KeyDown(KeyGet);
  g_tf=BrowserKeys[0x11];
  g_tb=BrowserKeys[0x1F];
  g_tl=BrowserKeys[0x1E];
  g_tr=BrowserKeys[0x20];
  g_tu=BrowserKeys[0x13];
  g_td=BrowserKeys[0x21];
  g_tjl=BrowserKeys[0x24];
  g_tjr=BrowserKeys[0x26];
  g_tpu=BrowserKeys[0x17];
  g_tpd=BrowserKeys[0x25];
  g_yaw+=BrowserMouseDX*MS_TURN;
  g_pitch-=BrowserMouseDY*MS_TURN;
  BrowserMouseDX=0;
  BrowserMouseDY=0;
}
#endif

U0 HandleInput()
{//Reads the input, runs the physics ticks due, then breaks or places.
  I64 i,lb,rb;
  F64 t=tS;
  InputRead;
  g_pitch=Clamp(g_pitch,-PITCH_MAX,PITCH_MAX);
  if (t-g_tick_t>0.25) g_tick_t=t-0.25;
  while (g_tick_t+TICK<=t) {
    g_tick_t+=TICK;
    PlayerTick;
  }
  lb=ms.lb;
  rb=ms.rb;
  if (lb && !g_plb && PickTarget) {
    g_world[WIdx(g_hx,g_hy,g_hz)]=0;
    ColsTop(g_hx,g_hz);
  }
  if (rb && !g_prb && PickTarget) {
    i=WIdx(g_bx,g_by,g_bz);
    g_world[i]=g_sel;
    if (PlayerHit(g_px,g_py,g_pz))
      g_world[i]=0;
    else
      ColsTop(g_bx,g_bz);
  }
  g_plb=lb;
  g_prb=rb;
}

U0 DrawHUD(U8 *b,I64 w,I64 h,I64 wi)
{//The cross to aim with and the bar of blocks to place, over the view.
  I64 i,t,blk,px,py,qx,c,cx=w/2-1,cy=h/2-1,
	aw=MaxI64(w/110,4),bw=w/17,gap=MaxI64(bw/8,1),bh=bw*3/4,
	x0=(w-16*bw)/2,y0=h-bh-MaxI64(bh/3,1);
  if (bw<3 || y0<=0 || cy+aw*3>=h) return;
  for (t=0;t<2;t++) {
    for (i=-aw;i<=aw*3;i++)
      b[(cy+i)*wi+cx+t]=WHITE;
    for (i=-aw;i<=aw;i++)
      b[(cy+t)*wi+cx+i]=WHITE;
  }
  for (blk=8;blk<24;blk++) {
    px=x0+(blk-8)*bw;
    c=g_lr[blk*4+2];
    for (py=y0;py<y0+bh;py++)
      for (qx=px+gap;qx<px+bw-gap;qx++)
	b[py*wi+qx]=c;
    if (blk==g_sel)
      for (qx=px-1;qx<px+bw;qx++) {
	b[(y0-1)*wi+qx]=WHITE;
	b[(y0+bh)*wi+qx]=WHITE;
      }
  }
}

#ifdef TOS_NATIVE
//Every corner of a face is a sum of one share for each of its coordinates,
//so two faces that meet get the same bits for their common corners.
F64 g_tfx[WX+1],g_trx[WX+1],g_tux[WX+1],g_tfy[WY+1],g_tuy[WY+1],
	g_tfz[WZ+1],g_trz[WZ+1],g_tuz[WZ+1],
	g_vf[4],g_vr[4],g_vu[4],g_wf[8],g_wr[8],g_wu[8],
	g_pnx[5],g_pnz[5],g_pk[5],g_sx[8],g_sy[8],g_sz[8];
I64 g_xa,g_xb,g_fog,g_fogc,g_syi[8];

U0 SkyRowsMake()
{//Random rows that blend each pair of sky colors in SKY_LVS steps.
  I64 i,j,q,p;
  U8 *dst;
  if (!g_skyrows)
    g_skyrows=MAlloc(2*(SKY_LVS+1)*SKY_ROW);
  dst=g_skyrows;
  for (i=0;i<2;i++)
    for (q=0;q<=SKY_LVS;q++) {
      p=q*65536/SKY_LVS;
      for (j=0;j<SKY_ROW;j++)
	if (RandU16<p)
	  *dst++=g_skyr[i+1];
	else
	  *dst++=g_skyr[i];
    }
}

U0 SkyFill()
{//Each row of sky by its height in the middle of the view.
  I64 sy,lv,q;
  F64 b,s;
  U8 *dst=g_win;
  for (sy=0;sy<g_sh;sy++) {
    b=(g_cyc-sy)/g_focal;
    s=2.0-SKY_K*(g_fwy+g_upy*b)/Sqrt(1.0+b*b);
    if (s<=0)
      MemSet(dst,g_skyr[0],g_sw);
    else if (s>=2 || g_sw>SKY_ROW-64)
      MemSet(dst,g_skyr[2],g_sw);
    else {
      lv=s;
      q=(s-lv)*SKY_LVS+0.5;
      q=(lv*(SKY_LVS+1)+q)*SKY_ROW;
      q+=RandU16&63;
      MemCpy(dst,g_skyrows+q,g_sw);
    }
    dst+=g_rdc->width_internal;
  }
}

U0 ViewMake()
{//Corner shares and the planes that bound the view, for this frame.
  I64 i;
  F64 t,th=(g_sw/2.0+2)/g_focal,tv=(g_sh/2.0+2)/g_focal,ny,ylo,yhi;
  for (i=0;i<=WX;i++) {
    t=i-g_cox;
    g_tfx[i]=t*g_fwx; g_trx[i]=t*g_rgx; g_tux[i]=t*g_upx;
  }
  for (i=0;i<=WY;i++) {
    t=i-g_coy;
    g_tfy[i]=t*g_fwy; g_tuy[i]=t*g_upy;
  }
  for (i=0;i<=WZ;i++) {
    t=i-g_coz;
    g_tfz[i]=t*g_fwz; g_trz[i]=t*g_rgz; g_tuz[i]=t*g_upz;
  }
  ylo=g_ylo-g_coy;
  yhi=g_yhi-g_coy;
  for (i=0;i<5;i++) {
    switch (i) {
      case 0: //In front.
	g_pnx[i]=g_fwx; g_pnz[i]=g_fwz; ny=g_fwy;
	break;
      case 1: //Not off the left, and so on.
	g_pnx[i]=g_rgx+th*g_fwx; g_pnz[i]=g_rgz+th*g_fwz; ny=th*g_fwy;
	break;
      case 2:
	g_pnx[i]=th*g_fwx-g_rgx; g_pnz[i]=th*g_fwz-g_rgz; ny=th*g_fwy;
	break;
      case 3:
	g_pnx[i]=g_upx+tv*g_fwx; g_pnz[i]=g_upz+tv*g_fwz; ny=g_upy+tv*g_fwy;
	break;
      case 4:
	g_pnx[i]=tv*g_fwx-g_upx; g_pnz[i]=tv*g_fwz-g_upz; ny=tv*g_fwy-g_upy;
	break;
    }
    g_pk[i]=Max(ny*ylo,ny*yhi)-g_pnx[i]*g_cox-g_pnz[i]*g_coz+
	  Max(g_pnx[i],0)+Max(g_pnz[i],0);
  }
}

Bool RowSpan(I64 z,F64 dz,F64 rr)
{//The columns of row z that can hold a face in view, g_xa to g_xb.
  I64 i;
  F64 half=Sqrt(rr-dz*dz),c,v;
  g_xa=ClampI64(Floor(g_cox-0.5-half),0,WX-1);
  g_xb=ClampI64(Floor(g_cox-0.5+half)+1,0,WX-1);
  for (i=0;i<5;i++) {
    c=g_pk[i]+g_pnz[i]*z;
    if (g_pnx[i]>0) {
      v=Clamp(-c/g_pnx[i],-2.0,WX+1.0);
      g_xa=MaxI64(g_xa,Floor(v));
    } else if (g_pnx[i]<0) {
      v=Clamp(-c/g_pnx[i],-2.0,WX+1.0);
      g_xb=MinI64(g_xb,Floor(v));
    } else if (c<0)
      return FALSE;
  }
  return g_xa<=g_xb;
}

U0 Corner(I64 i,I64 x,I64 y,I64 z)
{
  g_vf[i]=g_tfx[x]+g_tfy[y]+g_tfz[z];
  g_vr[i]=g_trx[x]+g_trz[z];
  g_vu[i]=g_tux[x]+g_tuy[y]+g_tuz[z];
}

I64 NearCut()
{//Corners g_vf, g_vr, g_vu, cut where the face is nearer than NEAR, into g_w*.
  I64 i,j,n=0;
  F64 t;
  for (i=0;i<4;i++) {
    j=i+1;
    if (j==4) j=0;
    if (g_vf[i]>=NEAR) {
      g_wf[n]=g_vf[i]; g_wr[n]=g_vr[i]; g_wu[n]=g_vu[i]; n++;
      if (g_vf[j]<NEAR) {
	t=(g_vf[i]-NEAR)/(g_vf[i]-g_vf[j]);
	g_wf[n]=NEAR;
	g_wr[n]=g_vr[i]+t*(g_vr[j]-g_vr[i]);
	g_wu[n]=g_vu[i]+t*(g_vu[j]-g_vu[i]);
	n++;
      }
    } else if (g_vf[j]>=NEAR) {
      t=(g_vf[j]-NEAR)/(g_vf[j]-g_vf[i]);
      g_wf[n]=NEAR;
      g_wr[n]=g_vr[j]+t*(g_vr[i]-g_vr[j]);
      g_wu[n]=g_vu[j]+t*(g_vu[i]-g_vu[j]);
      n++;
    }
  }
  return n;
}

U0 FaceFill(I64 color,I64 prob)
{//Subpixel edges share pixel centers; reciprocal depth is linear in x,y.
  I64 i,j,n,x1,x2,y,y1,y2,ya,yb,z1,z2,reg ex,reg dx,*dst,*end,
	ymin=I64_MAX,ymax=I64_MIN,side=3;
  F64 inv,ax,ay,bx,by,a,zx=0,zy=0,z0,
	slope,x,z,*vf,*vr,*vu;
  if (g_vf[0]>=NEAR && g_vf[1]>=NEAR &&
	g_vf[2]>=NEAR && g_vf[3]>=NEAR) {
    n=4;
    vf=g_vf;vr=g_vr;vu=g_vu;
  } else {
    n=NearCut;
    if (n<3) return;
    vf=g_wf;vr=g_wr;vu=g_wu;
  }
  for (i=0;i<n;i++) {
    inv=1.0/vf[i];
    g_sx[i]=g_cxc+vr[i]*g_focal*inv;
    if (side) {
      if (g_sx[i]>=-1.0) side&=~1;
      if (g_sx[i]<=g_sw+1.0) side&=~2;
    }
    g_sy[i]=g_cyc-vu[i]*g_focal*inv;
    g_sz[i]=ZFAR-g_zk*inv;
    g_syi[i]=Ceil(g_sy[i]-0.5);
    if (g_syi[i]<ymin) ymin=g_syi[i];
    if (g_syi[i]>ymax) ymax=g_syi[i];
  }
  y1=MaxI64(ymin,0);
  y2=MinI64(ymax-1,g_sh-1);
  if (side || y1>y2) return;
  for (i=1;i<n-1;i++) {
    ax=g_sx[i]-g_sx[0]; ay=g_sy[i]-g_sy[0];
    bx=g_sx[i+1]-g_sx[0]; by=g_sy[i+1]-g_sy[0];
    a=ax*by-ay*bx;
    if (Abs(a)>0.000001) {
      zx=((g_sz[i]-g_sz[0])*by-(g_sz[i+1]-g_sz[0])*ay)/a;
      zy=(ax*(g_sz[i+1]-g_sz[0])-bx*(g_sz[i]-g_sz[0]))/a;
      break;
    }
  }
  if (i==n-1) return;
  for (i=0;i<n;i++) {
    j=i+1; if (j==n) j=0;
    if (g_sy[i]!=g_sy[j]) {
      if (g_sy[j]>g_sy[i]) {
	ya=MaxI64(g_syi[i],0);
	yb=MinI64(g_syi[j]-1,g_sh-1);
      } else {
	ya=MaxI64(g_syi[j],0);
	yb=MinI64(g_syi[i]-1,g_sh-1);
      }
      slope=(g_sx[j]-g_sx[i])/(g_sy[j]-g_sy[i]);
      x=g_sx[i]+(ya+0.5-g_sy[i])*slope-0.5;
      ex=Floor(x*4294967296.0);
      dx=slope*4294967296.0;
      if (g_sy[j]>g_sy[i] ^^ a<0)
	dst=g_right;
      else
	dst=g_left;
      end=dst+yb+1;
      dst+=ya;
      while (dst<end) {
	*dst++=(ex+0xFFFFFFFF)>>32;
	ex+=dx;
      }
    }
  }
  z0=g_sz[0]-zx*(g_sx[0]-0.5)-zy*(g_sy[0]-0.5);
  if (color.u8[0]==color.u8[2])
    color&=~ROPF_PROBABILITY_DITHER;
  g_rdc->color=color;
  g_rdc->dither_probability_u16=prob;
  for (y=y1;y<=y2;y++) {
    x1=g_left[y]; x2=g_right[y]-1;
    x1=MaxI64(x1,0);
    x2=MinI64(x2,g_sw-1);
    if (x1<=x2) {
      z=z0+zy*y;
      z1=MaxI64(z+zx*x1,0);
      z2=MaxI64(z+zx*x2,0);
      GrHLine(g_rdc,x1,x2,y,z1,z2);
    }
  }
}

Bool FaceMatch(I64 x,I64 y,I64 z,I64 face,I64 block)
{//Coplanar faces may join before fog starts; their light is identical.
  I64 c=x+WX*(z+WZ*y);
  F64 dx=x+0.5-g_cox,dy=y+0.5-g_coy,dz=z+0.5-g_coz;
  if (dx*dx+dy*dy+dz*dz>=FOG0*FOG0 || g_world[c]!=block)
    return FALSE;
  switch (face) {
    case 0: return !g_world[c-1];
    case 1: return !g_world[c+1];
    case 2: return !g_world[c-WX*WZ];
    case 3: return y==WY-1 || !g_world[c+WX*WZ];
    case 4: return !g_world[c-WX];
    case 5: return !g_world[c+WX];
  }
  return FALSE;
}

U0 CellFace(I64 x,I64 y,I64 z,I64 face,I64 block)
{//An exposed face, joined with neighbors having the same material and light.
  I64 col,x1=x+1,y1=y+1,k=block*6+face;
  if (!g_fog) {
    if (face==2 || face==3) {
      if (x>g_xa && FaceMatch(x-1,y,z,face,block)) return;
      while (x1<=g_xb && FaceMatch(x1,y,z,face,block))
	x1++;
    } else {
      if (y>g_lo[x+WX*z] && FaceMatch(x,y-1,z,face,block)) return;
      while (y1<=g_hm[x+WX*z] && FaceMatch(x,y1,z,face,block))
	y1++;
    }
  }
  switch (face) {
    case 0:
    case 1:
      x+=face;
      Corner(0,x,y,z); Corner(1,x,y1,z);
      Corner(2,x,y1,z+1); Corner(3,x,y,z+1);
      break;
    case 2:
    case 3:
      y+=face-2;
      Corner(0,x,y,z); Corner(1,x1,y,z);
      Corner(2,x1,y,z+1); Corner(3,x,y,z+1);
      break;
    case 4:
    case 5:
      z+=face-4;
      Corner(0,x,y,z); Corner(1,x+1,y,z);
      Corner(2,x+1,y1,z); Corner(3,x,y1,z);
      break;
  }
  if (g_fog) {
    if (g_fthr[k]>=32768)
      col=g_fhi[k];
    else
      col=g_flo[k];
    FaceFill(ROPF_PROBABILITY_DITHER|g_fogc<<16|col,g_fog);
  } else
    FaceFill(ROPF_PROBABILITY_DITHER|g_fhi[k]<<16|g_flo[k],g_fthr[k]);
}

U0 FogSet(F64 d2,F64 dy)
{//How far the block at d2, the square of its distance, has faded.
  F64 d,s;
  if (d2<FOG0*FOG0)
    g_fog=0;
  else {
    d=Sqrt(d2);
    g_fog=ClampI64((d-FOG0)*65536/(RDIST-FOG0),1,65535);
    s=2.0-SKY_K*dy/d;
    if (s>=1.5)
      g_fogc=g_skyr[2];
    else if (s>=0.5)
      g_fogc=g_skyr[1];
    else
      g_fogc=g_skyr[0];
  }
}

U0 ColFaces(I64 x,I64 z,F64 dxz2)
{//The faces of column x,z that are open to the air and look at the eye.
  I64 y,h,block,c=x+WX*z;
  F64 dy,d2,far2=(RDIST+0.87)*(RDIST+0.87);
  U8 *w;
  h=g_hm[c];
  y=g_lo[c];
  w=g_world+c+WX*WZ*y;
  while (y<=h) {
    if (*w) {
      dy=y+0.5-g_coy;
      d2=dxz2+dy*dy;
      if (d2<far2) {
	FogSet(d2,dy);
	block=*w;
	if (g_coy>y+1 && (y==WY-1 || !w[WX*WZ]))
	  CellFace(x,y,z,3,block);
	if (g_coy<y && y && !w[-WX*WZ])
	  CellFace(x,y,z,2,block);
	if (g_cox<x && x && !w[-1])
	  CellFace(x,y,z,0,block);
	if (g_cox>x+1 && x<WX-1 && !w[1])
	  CellFace(x,y,z,1,block);
	if (g_coz<z && z && !w[-WX])
	  CellFace(x,y,z,4,block);
	if (g_coz>z+1 && z<WZ-1 && !w[WX])
	  CellFace(x,y,z,5,block);
      }
    }
    y++;
    w+=WX*WZ;
  }
}

Bool RenderFaces(CDC *dc)
{//The sky, then every face on air that looks at the eye, over a depth buffer.
  I64 need=dc->width_internal*dc->height,x,z,*edges;
  I32 *depth;
  F64 dx,dz,rr=(RDIST+0.75)*(RDIST+0.75);
  if (need<=0) return FALSE;
  if (need>g_depthcap) {
    depth=MAlloc(need*sizeof(I32));
    Free(g_depth);
    g_depth=depth;
    g_depthcap=need;
  }
  g_sw=dc->width; g_sh=dc->height;
  if (g_sh>g_edgecap) {
    edges=MAlloc(g_sh*2*sizeof(I64));
    Free(g_left);
    g_left=edges;
    g_right=g_left+g_sh;
    g_edgecap=g_sh;
  }
  g_win=dc->body;
  g_rdc=dc;
  SetupCam;
  g_cxc=g_sw/2.0;
  g_cyc=g_sh/2.0;
  g_focal=g_sh/2.0/FOV;
  g_zk=ZFAR*NEAR;
  dc->depth_buf=g_depth;
  MemSetU32(g_depth,I32_MAX,need);
  SkyFill;
  ViewMake;
  for (z=0;z<WZ;z++) {
    dz=z+0.5-g_coz;
    if (dz*dz<rr && RowSpan(z,dz,rr))
      for (x=g_xa;x<=g_xb;x++) {
	dx=x+0.5-g_cox;
	ColFaces(x,z,dx*dx+dz*dz);
      }
  }
  dc->depth_buf=NULL; //The buffer is ours: DCDel must not free it.
  return TRUE;
}

U0 DrawIt(CTask *task,CDC *dc)
{//Draw into a private DC; GrBlot clips windows and respects coverage.
  I64 w=task->pix_width,h=task->pix_height;
  CDC *view;
  if (w<=0 || h<=0) return;
  if (!g_view || g_view->width!=w || g_view->height!=h) {
    view=DCNew(w,h);
    view->flags|=DCF_NO_TRANSPARENTS;
    DCDel(g_view);
    g_view=view;
  }
  if (RenderFaces(g_view)) {
    DrawHUD(g_win,g_sw,g_sh,g_view->width_internal);
    GrBlot(dc,0,0,g_view);
  }
}
#else
F64 g_ent_t0,g_ent_t1;
I64 g_ent_axis,g_ent_ix,g_ent_iy,g_ent_iz;

U0 SlabCut(F64 o,F64 d,I64 size,I64 axis)
{//Narrows g_ent_t0 to g_ent_t1 to where o+d*t lies in 0 to size.
  F64 t1,t2;
  if (!d) {
    if (!(0<=o<size))
      g_ent_t1=-1.0;
  } else {
    t1=-o/d;
    t2=(size-o)/d;
    if (d<0) {
      t2=t1;
      t1=(size-o)/d;
    }
    if (t1>g_ent_t0) {
      g_ent_t0=t1;
      g_ent_axis=axis;
    }
    if (t2<g_ent_t1)
      g_ent_t1=t2;
  }
}

Bool RayEnter(F64 dx,F64 dy,F64 dz,F64 tlim)
{//Where a ray from an eye outside the world meets it before tlim.
  g_ent_t0=0.0;
  g_ent_t1=tlim;
  g_ent_axis=1;
  SlabCut(g_cox,dx,WX,0);
  SlabCut(g_coy,dy,WY,1);
  SlabCut(g_coz,dz,WZ,2);
  if (g_ent_t0>g_ent_t1)
    return FALSE;
  g_ent_ix=ClampI64(Floor(g_cox+dx*g_ent_t0),0,WX-1);
  g_ent_iy=ClampI64(Floor(g_coy+dy*g_ent_t0),0,WY-1);
  g_ent_iz=ClampI64(Floor(g_coz+dz*g_ent_t0),0,WZ-1);
  return TRUE;
}

U0 RenderFrame()
{//A ray a pixel into g_fb. Far blocks fade into the sky.
  F64 asp=1.0*RES_W/RES_H,cstep=2.0/RES_W*asp*FOV,fog_k=65536.0/(RDIST-FOG0),
	rgx,rgz,fx0,fx1,fy0,fy1,fz0,fz1,vy,bx,by,bz,row2,cx,
	dx,dy,dz,len2,inv,tlim,tdx,tdy,tdz,tmx,tmy,tmz,t,dist,s;
  I64 sx,sy,ix,iy,iz,ex,ey,ez,stx,sty,stz,sdy,sdz,fxf,fyf,fzf,
	idx,bidx,bt,b0=0,face,k,lv,rv,rv2,col;
  U8 *world=g_world,*fb=g_fb;
  U64 rng;
  Bool out;
  g_frame++;
  SetupCam;
  rgx=g_rgx; rgz=g_rgz;
  rng=g_frame*2654435761+12345;
  rng|=1;
  out=!(0<=g_cox<WX && 0<=g_coy<WY && 0<=g_coz<WZ);
  bidx=g_bix+WX*(g_biz+WZ*g_biy);
  if (!out)
    b0=world[bidx];
  fx1=g_bix+1-g_cox; fx0=g_cox-g_bix;
  fy1=g_biy+1-g_coy; fy0=g_coy-g_biy;
  fz1=g_biz+1-g_coz; fz0=g_coz-g_biz;
  for (sy=0;sy<RES_H;sy++) {
    vy=(1.0-2.0*sy/RES_H)*FOV;
    bx=g_fwx+g_upx*vy;
    by=g_fwy+g_upy*vy;
    bz=g_fwz+g_upz*vy;
    row2=1.0+vy*vy;
    cx=-asp*FOV;
    inv=1.0/Sqrt(row2+cx*cx);
    for (sx=0;sx<RES_W;sx++) {
      dx=bx+rgx*cx;
      dy=by;
      dz=bz+rgz*cx;
      len2=row2+cx*cx;
      inv*=1.5-0.5*len2*inv*inv; //Newton from the last pixel's 1/length.
      tlim=RDIST*inv;
      cx+=cstep;
      if (dx>0) {
	stx=1; ex=WX; fxf=0; tdx=1.0/dx; tmx=fx1*tdx;
      } else if (dx<0) {
	stx=-1; ex=-1; fxf=1; tdx=-1.0/dx; tmx=fx0*tdx;
      } else {
	stx=0; ex=0; fxf=1; tdx=0; tmx=1000000.0;
      }
      if (dy>0) {
	sty=1; ey=WY; sdy=WX*WZ; fyf=2; tdy=1.0/dy; tmy=fy1*tdy;
      } else if (dy<0) {
	sty=-1; ey=-1; sdy=-WX*WZ; fyf=3; tdy=-1.0/dy; tmy=fy0*tdy;
      } else {
	sty=0; ey=0; sdy=0; fyf=3; tdy=0; tmy=1000000.0;
      }
      if (dz>0) {
	stz=1; ez=WZ; sdz=WX; fzf=4; tdz=1.0/dz; tmz=fz1*tdz;
      } else if (dz<0) {
	stz=-1; ez=-1; sdz=-WX; fzf=5; tdz=-1.0/dz; tmz=fz0*tdz;
      } else {
	stz=0; ez=0; sdz=0; fzf=5; tdz=0; tmz=1000000.0;
      }
      ix=g_bix; iy=g_biy; iz=g_biz; idx=bidx;
      t=0; bt=b0; face=fyf;
      if (out) {
	if (RayEnter(dx,dy,dz,tlim)) {
	  ix=g_ent_ix; iy=g_ent_iy; iz=g_ent_iz;
	  idx=ix+WX*(iz+WZ*iy);
	  t=g_ent_t0;
	  bt=world[idx];
	  if (!g_ent_axis)
	    face=fxf;
	  else if (g_ent_axis==2)
	    face=fzf;
	  if (stx>0) tmx=(ix+1-g_cox)*tdx;
	  if (stx<0) tmx=(g_cox-ix)*tdx;
	  if (sty>0) tmy=(iy+1-g_coy)*tdy;
	  if (sty<0) tmy=(g_coy-iy)*tdy;
	  if (stz>0) tmz=(iz+1-g_coz)*tdz;
	  if (stz<0) tmz=(g_coz-iz)*tdz;
	} else
	  t=tlim+1;
      }
      while (!bt && t<=tlim) {
	if (tmx<tmy && tmx<tmz) {
	  ix+=stx;
	  if (ix==ex) break;
	  t=tmx; tmx+=tdx; idx+=stx; face=fxf;
	} else if (tmy<tmz) {
	  iy+=sty;
	  if (iy==ey) break;
	  t=tmy; tmy+=tdy; idx+=sdy; face=fyf;
	} else {
	  iz+=stz;
	  if (iz==ez) break;
	  t=tmz; tmz+=tdz; idx+=sdz; face=fzf;
	}
	bt=world[idx];
      }
      rng=rng*6364136223846793005+1442695040888963407;
      rv=rng>>48;
      if (bt) {
	dist=t*len2*inv;
	if (dist>FOG0) {
	  rv2=rng>>32&0xFFFF;
	  if ((dist-FOG0)*fog_k>rv2)
	    bt=0;
	}
      }
      if (bt) {
	k=bt*6+face;
	if (rv<g_fthr[k])
	  col=g_fhi[k];
	else
	  col=g_flo[k];
      } else {
	s=2.0-dy*inv*SKY_K;
	if (s<=0)
	  col=g_skyr[0];
	else if (s>=2)
	  col=g_skyr[2];
	else {
	  lv=s;
	  if (rv<(s-lv)*65536)
	    col=g_skyr[lv+1];
	  else
	    col=g_skyr[lv];
	}
      }
      *fb++=col;
    }
  }
}

#endif

U0 CleanUp()
{
  Free(g_world); g_world=NULL;
  Free(g_hm); g_hm=NULL;
  Free(g_lo); g_lo=NULL;
#ifdef TOS_NATIVE
  DCDel(g_view); g_view=NULL;
  Free(g_depth); g_depth=NULL; g_depthcap=0;
  Free(g_skyrows); g_skyrows=NULL;
  Free(g_left); g_left=NULL; g_right=NULL; g_edgecap=0;
#else
  Free(g_fb); g_fb=NULL;
#endif
}

U0 HolyCraft()
{
#ifdef TOS_NATIVE
  SettingsPush;
  try {
    AutoComplete;
    WinBorder;
    WinMax;
    DocCursor;
    DocClear;
    //The WinMgr leaves clicks to the game, and no Ctrl drag may scroll the
    //window: the faces would slide off the sky and the cross.
    Fs->win_inhibit|=WIF_SELF_MS_L|WIF_SELF_MS_R|WIG_DBL_CLICK|
	WIF_SELF_GRAB_SCROLL;
    Init;
    SkyRowsMake;
    //Clear keys left down from the launch command.
    g_scw=Char2ScanCode('w'); g_scs=Char2ScanCode('s');
    g_sca=Char2ScanCode('a'); g_scd=Char2ScanCode('d');
    g_scr=Char2ScanCode('r'); g_scf=Char2ScanCode('f');
    g_scj=Char2ScanCode('j'); g_scl=Char2ScanCode('l');
    g_sci=Char2ScanCode('i'); g_sck=Char2ScanCode('k');
    LBtr(kbd.down_bitmap,g_scw); LBtr(kbd.down_bitmap,g_scs);
    LBtr(kbd.down_bitmap,g_sca);
    LBtr(kbd.down_bitmap,g_scd); LBtr(kbd.down_bitmap,g_scr);
    LBtr(kbd.down_bitmap,g_scf);
    LBtr(kbd.down_bitmap,g_scj); LBtr(kbd.down_bitmap,g_scl);
    LBtr(kbd.down_bitmap,g_sci);
    LBtr(kbd.down_bitmap,g_sck);
    FlushMsgs;
    MsSet(320,240);
    BrowserMouseCapture=1;
    Fs->draw_it=&DrawIt;
    while (!g_quit) {
      HandleInput;
      Sleep(16);
    }
  } catch
    PutExcept;
  BrowserMouseCapture=0;
  SettingsPop;
  CleanUp;
#else
  CDC *dc=NULL;
  try {
    dc=DCAlias;
    Init;
    BrowserMouseCapture=1;
    while (!g_quit) {
      HandleInput;
      RenderFrame;
      DrawHUD(g_fb,RES_W,RES_H,RES_W);
      GrSprite(dc,0,0,g_fb,RES_W,RES_H,SCALE);
      Sleep(16);
    }
  } catch
    PutExcept;
  if (dc) DCFill(dc,BLACK);
  BrowserMouseCapture=0;
  DCDel(dc);
  CleanUp;
#endif
}

HolyCraft;
