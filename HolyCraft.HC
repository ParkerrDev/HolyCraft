//HolyCraft: walk a world of blocks, break them and place new ones.
//W S A D walk, the mouse or J L I K look, Space jumps, G flies, R F rise
//and sink, left click breaks, right click places, 1 to 9 and Q E pick a
//block, Esc quits.
//
//Two builds. In the browser (HolyC-wasm) a ray a pixel draws the frame,
//blitted with GrSprite. In TempleOS (Run.HC defines TOS_NATIVE) DrawIt
//fills the exposed faces with GrFillPoly3 over a depth buffer.
#ifdef TOS_NATIVE
#define RDIST		32.0	//Render distance, cells.
#define FOG0		20.0	//Fog starts here and is all sky at RDIST.
#else
#define RES_W		640
#define RES_H		480
#define SCALE		1
#define RDIST		48.0
#define FOG0		32.0
#define SKY_K		2.0	//Sky ramp steps a unit of elevation sine.
#endif
#define FOV		1.05	//Half the view's height at distance 1.
#define WX      128           // world size
#define WZ      128
#define WY      40
#define WATER   5
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

U8  *g_world = NULL;         // WX*WZ*WY voxels, 0 = air
U8  *g_fb    = NULL;         //The browser's frame, RES_W*RES_H.
U8   g_skyr[3];             // sky gradient ramp (blue zenith -> ltblue -> ltcyan horizon)
U8   g_lr[24*4];            // per-block ramp, 4 levels dark->bright. 0=air; 1-7 materials; 8-23 = the 16 system colors
U8   g_flo[24*6], g_fhi[24*6]; // per (block,face): the 2 ramp colors bracketing that face's light shade
I64  g_fthr[24*6];          // per (block,face): probability 0..65536 for the LIVE "static" dither blend
U8  *g_hm    = NULL;         // per (x,z): top solid y (heightmap) -> bounds the native exposed-face scan
I64  g_frame = 0;           // frame counter -> reseeds the dither each frame so it animates (like Varoom)
F64  g_px, g_py, g_pz;       // camera position
F64  g_yaw, g_pitch;         // camera angles
I64  g_sel  = 8;             // selected block to place (8..23 = the 16 palette-colour blocks)
I64  g_plb  = 0, g_prb = 0;  // previous mouse button states (edge detect)
// Optional browser input bridge. Native TempleOS uses its keyboard and MsSet;
// holyc-wasm fills these globals from the focused canvas's shared input state.
I64 BrowserMouseCapture=0, BrowserMouseDX=0, BrowserMouseDY=0;
U8 BrowserKeys[128];
I64 g_tf,g_tb,g_tl,g_tr,g_tu,g_td,g_tjl,g_tjr,g_tpu,g_tpd; //Keys held.
F64 g_vy=0.0,g_tick_t; //Up speed, and the time of the last physics tick.
I64 g_fly=0,g_onground=0,g_quit=0;
#ifdef TOS_NATIVE
// native face-rasterizer state (declared before Init, which allocates g_depth). CDC is an OS type, so
// these stay inside TOS_NATIVE (the browser/holyc-wasm target never sees them).
I32 *g_depth = NULL;          // z-buffer (I32/px; smaller==nearer; cleared to I32_MAX); attached to the DC each frame
I64  g_depthcap = 1024*768;   // z-buffer capacity in px (covers any sane screen)
F64  g_focal, g_cxc, g_cyc;   // perspective focal length (px) + screen centre (set per frame from the DC size)
I64  g_sw, g_sh;              // screen width/height (px) -- for the off-screen face reject in DrawFace
CDC *g_rdc = NULL;            // the DC the current frame's faces fill (set at the top of RenderFaces)
// scancodes of the held-movement keys, precomputed once (Char2ScanCode is slow). On real TempleOS we
// POLL kbd.down_bitmap each frame for these (robust held-key state, like Demo/Games/RainDrops.HC) instead
// of tracking make/break messages - a lost KEY_UP can't leave you "stuck walking" that way.
I64 g_scw,g_scs,g_sca,g_scd,g_scr,g_scf,g_scj,g_scl,g_sci,g_sck;
#endif

I64 WIdx(I64 x, I64 y, I64 z)
{
  return x + WX*(z + WZ*y);
}

I64 Solid(I64 x, I64 y, I64 z)
{
  if (x<0 || x>=WX || z<0 || z>=WZ || y<0 || y>=WY) return 0;
  return g_world[WIdx(x,y,z)];
}

I64 HeightAt(I64 x, I64 z)
{
  F64 h = 14.0 + 4.0*Sin(x*0.16) + 4.0*Cos(z*0.15) + 2.5*Sin((x+z)*0.08) + 2.0*Cos((x-z)*0.11);
  I64 hi = h;
  if (hi<2) hi=2;
  if (hi>WY-8) hi=WY-8;
  return hi;
}

U0 SetRamp()
{
  I64 c; U8 dk[16], lt[16];
  g_skyr[0]=1; g_skyr[1]=9; g_skyr[2]=11;                 // sky: blue -> ltblue -> ltcyan
  // Materials (terrain). 4-level ramp dark->bright; face lighting + the live dither blend the two
  // bracketing colors. Darken with BLACK (not gray) so shading stays the material's hue.
  g_lr[1*4+0]=0;  g_lr[1*4+1]=2;  g_lr[1*4+2]=10; g_lr[1*4+3]=10;   // grass  black->green->ltgreen
  g_lr[2*4+0]=0;  g_lr[2*4+1]=6;  g_lr[2*4+2]=6;  g_lr[2*4+3]=14;   // dirt   black->brown->yellow
  g_lr[3*4+0]=0;  g_lr[3*4+1]=8;  g_lr[3*4+2]=7;  g_lr[3*4+3]=15;   // stone  black->dkgray->ltgray->white
  g_lr[4*4+0]=0;  g_lr[4*4+1]=6;  g_lr[4*4+2]=6;  g_lr[4*4+3]=14;   // wood
  g_lr[5*4+0]=0;  g_lr[5*4+1]=2;  g_lr[5*4+2]=10; g_lr[5*4+3]=10;   // leaves
  g_lr[6*4+0]=6;  g_lr[6*4+1]=14; g_lr[6*4+2]=14; g_lr[6*4+3]=15;   // sand   brown->yellow->white
  g_lr[7*4+0]=1;  g_lr[7*4+1]=9;  g_lr[7*4+2]=11; g_lr[7*4+3]=11;   // water  blue->ltblue->ltcyan
  // The 16 system colours are blocks 8..23 (block 8+c = palette colour c) -> the placeable hotbar. These are
  // the 16 DISTINCT colours; the 7 terrain materials (1..7) each duplicate one of these hues (grass/leaves=
  // green, dirt/wood=brown, stone=gray, sand=yellow, water=cyan) so they're kept for terrain/trees but NOT
  // shown in the hotbar (no duplicate swatches).
  dk[0] =0; dk[1] =0; dk[2] =0;  dk[3] =1;  dk[4] =0;  dk[5] =0;  dk[6] =0;  dk[7] =8;   // darker shade per color
  dk[8] =0; dk[9] =1; dk[10]=2;  dk[11]=9;  dk[12]=4;  dk[13]=5;  dk[14]=6;  dk[15]=7;
  lt[0] =8; lt[1] =9; lt[2] =10; lt[3] =11; lt[4] =12; lt[5] =13; lt[6] =14; lt[7] =15;  // brighter shade per color
  lt[8] =7; lt[9] =11;lt[10]=15; lt[11]=15; lt[12]=14; lt[13]=15; lt[14]=15; lt[15]=15;
  for (c=0; c<16; c++) {
    g_lr[(8+c)*4+0]=dk[c]; g_lr[(8+c)*4+1]=c; g_lr[(8+c)*4+2]=c; g_lr[(8+c)*4+3]=lt[c];
  }
}

U0 BuildFaceShades()
{   // Directional per-face lighting: dot each of the 6 cube-face normals with a fixed light direction to
    // get 6 brightness levels, and resolve each to (two ramp colors + dither threshold). Done ONCE -> the
    // hot loop is a single table lookup per pixel. Face order: 0=-X 1=+X 2=-Y 3=+Y 4=-Z 5=+Z.
  F64 Lx=0.394, Ly=0.788, Lz=0.473, amb=0.30;   // light dir (above + +x/+z), pre-normalized
  I64 f, bt;
  for (f=0; f<6; f++) {
    F64 d;
    if      (f==0) d=-Lx; else if (f==1) d=Lx;
    else if (f==2) d=-Ly; else if (f==3) d=Ly;
    else if (f==4) d=-Lz; else          d=Lz;
    if (d<0.0) d=0.0;
    F64 p=(amb+(1.0-amb)*d)*3.0;          // brightness 0..1 -> ramp position 0..3
    I64 lo=p; if (lo>2) lo=2;
    F64 fr=p-lo; if (fr<0.0) fr=0.0; if (fr>1.0) fr=1.0;
    for (bt=1; bt<=23; bt++) {              // 7 materials (terrain) + the 16 palette-colour blocks (8..23)
      g_flo[bt*6+f] =g_lr[bt*4+lo];
      g_fhi[bt*6+f] =g_lr[bt*4+lo+1];
      g_fthr[bt*6+f]=fr*65536.0;            // probability the pixel takes the brighter color (live dither)
      if (g_fthr[bt*6+f]>65535) g_fthr[bt*6+f]=65535;   // clamp for the U16 dither_probability field
    }
  }
}

U0 PlantTree(I64 x, I64 top, I64 z)
{
  I64 dy,lx,ly,lz;
  for (dy=0; dy<4; dy++)
    if (top+dy<WY) g_world[WIdx(x,top+dy,z)]=4;            // trunk
  for (ly=top+3; ly<=top+5; ly++)
    for (lx=x-2; lx<=x+2; lx++)
      for (lz=z-2; lz<=z+2; lz++)              // (no `continue` - TempleOS HolyC has no such keyword)
        if (!Solid(lx,ly,lz))
          if ((lx-x)*(lx-x)+(lz-z)*(lz-z)+(ly-top-4)*(ly-top-4) <= 6)
            if (lx>=0 && lx<WX && lz>=0 && lz<WZ && ly<WY) g_world[WIdx(lx,ly,lz)]=5;
}

U0 GenWorld()
{
  I64 x,z,y,h;
  for (x=0; x<WX; x++)
    for (z=0; z<WZ; z++) {
      h = HeightAt(x,z);
      for (y=0; y<WY; y++) {
        I64 b=0;
        if (y<h-3)      b=3;        // stone
        else if (y<h-1) b=2;        // dirt
        else if (y<h)   b=1;        // grass (top)
        if (b==0 && y<=WATER && y>=h) b=7;   // water above low terrain
        if (b==1 && h<=WATER+1) b=6;          // sand at the shoreline
        g_world[WIdx(x,y,z)]=b;
      }
      if (h>WATER+1 && ((x*7+z*13)%53)==0) PlantTree(x,h,z);
    }
}

// heightmap = the top solid voxel of each (x,z) column. The native face-rasterizer walks this "shell"
// (top face + the side faces exposed wherever a neighbour column is lower) instead of every voxel.
U0 ColTop(I64 x, I64 z)
{
  I64 y, top=0;
  for (y=WY-1; y>=0; y--)
    if (g_world[WIdx(x,y,z)]) { top=y; break; }
  g_hm[x+WX*z]=top;
}

U0 BuildHM()
{
  I64 x,z;
  for (x=0; x<WX; x++)
    for (z=0; z<WZ; z++) ColTop(x,z);
}

U0 Init()
{
  g_tf=0; g_tb=0; g_tl=0; g_tr=0; g_tu=0; g_td=0;
  g_tjl=0; g_tjr=0; g_tpu=0; g_tpd=0;
  g_world = MAlloc(WX*WZ*WY);
  g_hm    = MAlloc(WX*WZ);
#ifdef TOS_NATIVE
  g_depth=MAlloc(g_depthcap*sizeof(I32));
#else
  g_fb=MAlloc(RES_W*RES_H);
#endif
  SetRamp();
  BuildFaceShades();
  GenWorld();
  BuildHM();
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

// raycast from the camera center to the first solid voxel; returns hit + the
// empty cell just before it (for placing). out_* via globals.
I64 g_hx,g_hy,g_hz, g_bx,g_by,g_bz;   // hit cell, and the air cell before it
I64 PickTarget()
{
  F64 cp=Cos(g_pitch), sp=Sin(g_pitch), cy=Cos(g_yaw), sy=Sin(g_yaw);
  F64 dx=sy*cp, dy=sp, dz=cy*cp;
  F64 ox=g_px, oy=g_py, oz=g_pz;
  I64 ix=Floor(ox), iy=Floor(oy), iz=Floor(oz), px=ix,py=iy,pz=iz;
  F64 adx=Abs(dx),ady=Abs(dy),adz=Abs(dz);
  I64 stx,sty,stz; F64 tdx,tdy,tdz,tmx,tmy,tmz;
  if (dx>0.0){stx=1;tdx=1.0/adx;tmx=(ix+1-ox)*tdx;}else if(dx<0.0){stx=-1;tdx=1.0/adx;tmx=(ox-ix)*tdx;}else{stx=0;tdx=1000000.0;tmx=1000000.0;}
  if (dy>0.0){sty=1;tdy=1.0/ady;tmy=(iy+1-oy)*tdy;}else if(dy<0.0){sty=-1;tdy=1.0/ady;tmy=(oy-iy)*tdy;}else{sty=0;tdy=1000000.0;tmy=1000000.0;}
  if (dz>0.0){stz=1;tdz=1.0/adz;tmz=(iz+1-oz)*tdz;}else if(dz<0.0){stz=-1;tdz=1.0/adz;tmz=(oz-iz)*tdz;}else{stz=0;tdz=1000000.0;tmz=1000000.0;}
  I64 step; F64 t=0.0;
  for (step=0; step<48; step++) {
    px=ix; py=iy; pz=iz;
    if (tmx<tmy && tmx<tmz){ix+=stx;t=tmx;tmx+=tdx;}
    else if (tmy<tmz)      {iy+=sty;t=tmy;tmy+=tdy;}
    else                   {iz+=stz;t=tmz;tmz+=tdz;}
    if (t>6.0) return 0;
    if (Solid(ix,iy,iz)) { g_hx=ix;g_hy=iy;g_hz=iz; g_bx=px;g_by=py;g_bz=pz; return 1; }
  }
  return 0;
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
  } else if (ch==CH_ESC)
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
    ColTop(g_hx,g_hz);
  }
  if (rb && !g_prb && PickTarget) {
    i=WIdx(g_bx,g_by,g_bz);
    g_world[i]=g_sel;
    if (PlayerHit(g_px,g_py,g_pz))
      g_world[i]=0;
    else
      ColTop(g_bx,g_bz);
  }
  g_plb=lb;
  g_prb=rb;
}

#ifdef TOS_NATIVE
// ===== native FACE-RASTERIZER ====================================================================
// Instead of one DDA ray per pixel (~302K rays/frame -> ~0.4fps in the x86 emulator), draw the world's
// exposed block FACES as filled z-buffered 3D quads via the OS primitive GrFillPoly3(). Its inner span
// filler GrFillRow is HLE-accelerated by HEMU (the SAME native-speed path that lets Varoom hit 30fps),
// and it z-buffers through dc->depth_buf so faces occlude correctly + each pixel is written ~once.
// We do the perspective projection ourselves (matching RenderRows' fov=1.05 / camera basis). Every
// "var - var" below is deliberate: real TempleOS HolyC mis-compiles "literal - <mul/div expr>".
I64 ProjPt(F64 wxf, F64 wyf, F64 wzf, CD3I32 *p)
{//world -> screen (x,y px) + depth z (>0, nearer==smaller). Returns 0 if behind the near plane.
  F64 rx, ry, rz, fd, rt, upc, inv, dxv, dyv, dzv;
  I64 tx, ty, tz;
  rx = wxf - g_px; ry = wyf - g_py; rz = wzf - g_pz;
  fd = rx*g_fwx + ry*g_fwy + rz*g_fwz;          // forward = camera-space depth
  if (fd < 0.2) return 0;
  rt  = rx*g_rgx + rz*g_rgz;                     // right (rgy is always 0)
  upc = rx*g_upx + ry*g_upy + rz*g_upz;          // up
  inv = g_focal / fd;
  dxv = rt*inv;  dyv = upc*inv;
  tx = g_cxc + dxv;  p->x = tx;                  // + is commutative -> codegen-safe
  ty = g_cyc - dyv;  p->y = ty;                  // var - var (NOT literal - expr)
  dzv = fd * 256.0;  tz = dzv;  p->z = tz;
  return 1;
}

U0 DrawFace(I64 cx, I64 cy0, I64 cy1, I64 cz, I64 faceid, I64 bt)
{//one face spanning cells cy0..cy1 vertically (cy0==cy1 = single cell). face 0=-X 1=+X 2=-Y 3=+Y 4=-Z 5=+Z.
  CD3I32 poly[4];
  F64 ax, ay, az, bx, by, bz;
  I64 ok=0;
  ax=cx; ay=cy0; az=cz; bx=cx+1; by=cy1+1; bz=cz+1;
  if      (faceid==3) { ok+=ProjPt(ax,by,az,&poly[0]); ok+=ProjPt(bx,by,az,&poly[1]); ok+=ProjPt(bx,by,bz,&poly[2]); ok+=ProjPt(ax,by,bz,&poly[3]); }
  else if (faceid==2) { ok+=ProjPt(ax,ay,az,&poly[0]); ok+=ProjPt(ax,ay,bz,&poly[1]); ok+=ProjPt(bx,ay,bz,&poly[2]); ok+=ProjPt(bx,ay,az,&poly[3]); }
  else if (faceid==0) { ok+=ProjPt(ax,ay,az,&poly[0]); ok+=ProjPt(ax,by,az,&poly[1]); ok+=ProjPt(ax,by,bz,&poly[2]); ok+=ProjPt(ax,ay,bz,&poly[3]); }
  else if (faceid==1) { ok+=ProjPt(bx,ay,az,&poly[0]); ok+=ProjPt(bx,ay,bz,&poly[1]); ok+=ProjPt(bx,by,bz,&poly[2]); ok+=ProjPt(bx,by,az,&poly[3]); }
  else if (faceid==4) { ok+=ProjPt(ax,ay,az,&poly[0]); ok+=ProjPt(bx,ay,az,&poly[1]); ok+=ProjPt(bx,by,az,&poly[2]); ok+=ProjPt(ax,by,az,&poly[3]); }
  else                { ok+=ProjPt(ax,ay,bz,&poly[0]); ok+=ProjPt(ax,by,bz,&poly[1]); ok+=ProjPt(bx,by,bz,&poly[2]); ok+=ProjPt(bx,ay,bz,&poly[3]); }
  if (ok==4) {
    // cheap reject: skip the (emulated, costly) GrFillPoly3 when the whole quad is off one screen edge
    if (poly[0].x<0    && poly[1].x<0    && poly[2].x<0    && poly[3].x<0)    return;
    if (poly[0].x>=g_sw && poly[1].x>=g_sw && poly[2].x>=g_sw && poly[3].x>=g_sw) return;
    if (poly[0].y<0    && poly[1].y<0    && poly[2].y<0    && poly[3].y<0)    return;
    if (poly[0].y>=g_sh && poly[1].y>=g_sh && poly[2].y>=g_sh && poly[3].y>=g_sh) return;
    // LIVE probability dither between the two ramp colours bracketing this face's light shade -- the OS's
    // GrFillRow (HLE-accelerated) rolls RandU16<prob per pixel, EXACTLY like the browser raycaster's dither,
    // so the native build gets the same >16-colour blended look. (canonical idiom: dither + c2<<16 + c1.)
    I64 k = bt*6+faceid;
    g_rdc->color = ROPF_PROBABILITY_DITHER + g_fhi[k] << 16 + g_flo[k];
    g_rdc->dither_probability_u16 = g_fthr[k];
    GrFillPoly3(g_rdc, 4, poly);
  }
}

U0 SideRun(I64 x, I64 z, I64 h, I64 faceid, I64 noff)
{//merge a vertical run of same-block faces (neighbour cell base+noff is air) into ONE tall quad -> far fewer
 //GrFillPoly3 calls for trunks/cliffs/canopy sides. Caller already did the back-face (front-facing) test.
  I64 y=0, y2, bt, base, b2;
  while (y<=h) {
    base = x + WX*(z + WZ*y);
    bt = g_world[base];
    if (bt && !g_world[base+noff]) {
      y2=y;
      while (y2+1<=h) {
        b2 = x + WX*(z + WZ*(y2+1));
        if (g_world[b2]==bt && !g_world[b2+noff]) y2=y2+1; else break;
      }
      DrawFace(x,y,y2,z,faceid,bt);
      y=y2+1;
    } else
      y=y+1;
  }
}

U0 RenderFaces(CDC *dc)
{
  I64 need, R, bix, biz, xa, xb, za, zb, x, z, y, h, bt, bidx;
  F64 hw, hh, rcx, rcz, fdc, prp;
  g_rdc = dc;
  SetupCam();                                   // camera basis + g_bix/g_biz (ProjPt reads the basis)
  g_sw=dc->width; g_sh=dc->height;
  hw=g_sw;  hw=hw/2.0;  g_cxc=hw;
  hh=g_sh;  hh=hh/2.0;  g_cyc=hh;
  g_focal = hh / 1.05;                           // (H/2)/fov : same view as RenderRows (fov=1.05)
  need = dc->width_internal * dc->height;
  if (need > g_depthcap) return;
  dc->depth_buf = g_depth;                       // attach our z-buffer ...
  MemSetU32(g_depth, I32_MAX, need);             // ... cleared to "far away"
  MemSet(dc->body, 11, need);                    // sky (ltcyan); faces overwrite it
  R=RDIST; bix=g_bix; biz=g_biz;
  xa=bix-R; xb=bix+R; za=biz-R; zb=biz+R;
  if (xa<1) xa=1;  if (xb>WX-2) xb=WX-2;
  if (za<1) za=1;  if (zb>WZ-2) zb=WZ-2;
  for (z=za; z<=zb; z++)
    for (x=xa; x<=xb; x++) {
      rcx = x - g_px;  rcz = z - g_pz;            // frustum cull: skip columns behind OR well outside the FOV cone
      fdc = rcx*g_fwx + rcz*g_fwz;                 //   forward distance (along the look direction)
      prp = rcx*g_rgx + rcz*g_rgz; if (prp<0.0) prp=-prp;   // |sideways| distance (the right axis)
      if (fdc >= -2.0 && prp <= fdc*3.0 + 8.0) {  // cone widens with distance (generous margin -> no edge pop)
        h = g_hm[x+WX*z];                          // top solid cell of this column (nothing solid above it)
        for (y=0; y<=h; y++) {                     // TOP/BOTTOM faces per cell (horizontal -> can't vertical-merge)
          bidx = x + WX*(z + WZ*y);                // (buried interior cells here are just cheap reads)
          bt = g_world[bidx];
          if (bt) {                                // x in [1,WX-2], z in [1,WZ-2] -> x/z neighbours in-bounds
            if ((y>=WY-1 || !g_world[bidx + WX*WZ]) && g_py>y+1) DrawFace(x,y,y,z,3,bt);   // +Y top
            if (y>0 && !g_world[bidx - WX*WZ]       && g_py<y)   DrawFace(x,y,y,z,2,bt);   // -Y bottom
          }
        }
        if (g_px<x)   SideRun(x,z,h,0,-1);          // SIDE faces: merge each vertical run into ONE tall quad
        if (g_px>x+1) SideRun(x,z,h,1,+1);          //   (-X +X -Z +Z; neighbour offset -1 +1 -WX +WX)
        if (g_pz<z)   SideRun(x,z,h,4,-WX);
        if (g_pz>z+1) SideRun(x,z,h,5,+WX);
      }
    }
  dc->depth_buf = NULL;                           // detach (the buffer is ours; DCDel must not free it)
}

U0 DrawHUDDC(CDC *dc)
{//crosshair + hotbar straight into the window body (2D, on top of the rendered world)
  U8 *b=dc->body;
  I64 W=dc->width, H=dc->height, st=dc->width_internal, cx=W/2, cy=H/2, i;
  I64 aw=W/110, t; if (aw<4) aw=4;                           // Latin (Christian) cross crosshair (aim at the crossing)
  for (t=0; t<2; t++) {
    for (i=-aw; i<=aw*3; i++) b[(cy+i)*st + cx+t]=15;        // vertical stem
    for (i=-aw; i<=aw;   i++) b[(cy+t)*st + cx+i]=15;        // crossbar (near the top)
  }
  I64 nb=16, bw=W/17, gap=bw/8, bsel;
  if (gap<1) gap=1;
  I64 bh=bw*3/4, x0=(W-nb*bw)/2, y0=H-bh-bh/3;
  for (bsel=0; bsel<nb; bsel++) {
    I64 blk=8+bsel, px=x0+bsel*bw, py, qx, c=g_lr[blk*4+2];
    for (py=y0; py<y0+bh; py++)
      for (qx=px+gap; qx<px+bw-gap; qx++) b[py*st+qx]=c;
    if (blk==g_sel)
      for (qx=px-1; qx<px+bw; qx++) { b[(y0-1)*st+qx]=15; b[(y0+bh)*st+qx]=15; }
  }
}

// real TempleOS calls this each refresh with the window DC -> render the world fresh, Varoom-style.
U0 DrawIt(CTask *task, CDC *dc)
{
  no_warn task;
  if (!g_world) return;
  RenderFaces(dc);
  DrawHUDDC(dc);
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

U0 DrawHUD()
{
  I64 cx=RES_W/2, cy=RES_H/2, i;
  I64 aw=RES_W/110, t; if (aw<4) aw=4;                       // crosshair = a Latin (Christian) cross: short top + crossbar, long lower stem; you aim at the crossing
  for (t=0; t<2; t++) {                                       // 2px thick
    for (i=-aw; i<=aw*3; i++) g_fb[(cy+i)*RES_W + cx+t]=15;   // vertical stem (top stub aw, lower stem 3aw)
    for (i=-aw; i<=aw;   i++) g_fb[(cy+t)*RES_W + cx+i]=15;   // crossbar (near the top)
  }
  // hotbar: 7 swatches along the bottom, sized RELATIVE to the resolution (so it isn't huge at low res
  // or invisible at high res). gap framing inside each cell; selected one framed white.
  I64 nb=16, bw=RES_W/17, gap=bw/8, b;                       // 16 placeable blocks = the palette colours (8..23)
  if (gap<1) gap=1;
  I64 bh=bw*3/4, x0=(RES_W-nb*bw)/2, y0=RES_H-bh-bh/3;       // squarish swatches near the bottom
  for (b=0; b<nb; b++) {
    I64 blk=8+b, px=x0+b*bw, py, qx;
    I64 c=g_lr[blk*4+2];                                     // representative shade of the colour block
    for (py=y0; py<y0+bh; py++)
      for (qx=px+gap; qx<px+bw-gap; qx++) g_fb[py*RES_W+qx]=c;
    if (blk==g_sel)
      for (qx=px-1; qx<px+bw; qx++) { g_fb[(y0-1)*RES_W+qx]=15; g_fb[(y0+bh)*RES_W+qx]=15; }
  }
}

U0 Present(CDC *dc)
{
  GrSprite(dc, 0, 0, g_fb, RES_W, RES_H, SCALE);   // holyc-wasm blits the 8-bit buffer
}
#endif

U0 HolyCraft()
{
#ifdef TOS_NATIVE
  SettingsPush;
  AutoComplete(OFF);            // don't pop the completion box while we read keys
  WinBorder(OFF);
  WinMax;
  DocCursor(OFF);
  DocClear;
  // Inhibit the window manager from acting on clicks (no window close/drag/menu/double-click) while we play
  // - exactly what real-time apps do (reference ToTheFront.HC:135, MassSpring.HC). Clicks still set
  // ms.lb/ms.rb so break/place keep working, but a stray click can no longer drop you out of the game.
  Fs->win_inhibit|=WIF_SELF_MS_L|WIF_SELF_MS_R|WIG_DBL_CLICK;
  Init();
  // precompute the held-key scancodes once (Char2ScanCode is slow), then CLEAR any of them the kernel still
  // has marked "down" from the launch keystrokes (the 'a' in "HolyCraft.HC" etc.) and FLUSH their messages,
  // so you spawn standing still instead of strafing. This is the base-TempleOS stand-in for KeyStateRst.
  g_scw=Char2ScanCode('w'); g_scs=Char2ScanCode('s'); g_sca=Char2ScanCode('a'); g_scd=Char2ScanCode('d');
  g_scr=Char2ScanCode('r'); g_scf=Char2ScanCode('f'); g_scj=Char2ScanCode('j'); g_scl=Char2ScanCode('l');
  g_sci=Char2ScanCode('i'); g_sck=Char2ScanCode('k');
  LBtr(kbd.down_bitmap,g_scw); LBtr(kbd.down_bitmap,g_scs); LBtr(kbd.down_bitmap,g_sca);
  LBtr(kbd.down_bitmap,g_scd); LBtr(kbd.down_bitmap,g_scr); LBtr(kbd.down_bitmap,g_scf);
  LBtr(kbd.down_bitmap,g_scj); LBtr(kbd.down_bitmap,g_scl); LBtr(kbd.down_bitmap,g_sci);
  LBtr(kbd.down_bitmap,g_sck);
  FlushMsgs;
  MsSet(320,240);
  BrowserMouseCapture=1;
  Fs->draw_it=&DrawIt;          // the WinMgr now renders the world (faces) to the screen DC every refresh
  try {
    while (!g_quit) {
      HandleInput();            // input + physics only; DrawIt does all the rendering (Varoom-style)
      Sleep(16);
    }
  } catch
    PutExcept;
  Fs->draw_it=NULL;
  BrowserMouseCapture=0;
  Fs->win_inhibit=WIG_USER_TASK_DFT;   // hand mouse handling back to the window manager
  DocClear;
  SettingsPop;
#else
  Init();
  BrowserMouseCapture=1;
  CDC *dc=DCAlias;
  while (!g_quit) {
    HandleInput();
    RenderFrame();
    DrawHUD();
    Present(dc);
    Sleep(16);
  }
  DCFill(dc, BLACK);
  BrowserMouseCapture=0;
  "HolyCraft: thanks for playing!\n";
#endif
}

HolyCraft;
