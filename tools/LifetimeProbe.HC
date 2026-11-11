U0 ProbeEmpty()
{
  ProbeChk(!probe_live && !g_world && !g_hm && !g_lo && !g_view &&
	!g_depth && !g_depthcap && !g_left && !g_right && !g_edgecap &&
	!g_skyrows && !BrowserMouseCapture);
}

U0 ProbeExit(CTask *task)
{
  while (!BrowserMouseCapture) Sleep(1);
  PostMsg(task,MSG_KEY_DOWN,CH_ESC,SC_ESC);
}

U0 LifetimeProbe(Bool startup=TRUE)
{
  I64 i,old_draw=Fs->draw_it,old_inhibit=Fs->win_inhibit,
	old_settings=Fs->next_settings,old_depthcap,old_edgecap,*old_left;
  I32 *old_depth;
  CDC *dc,*old_view;
  CTask *task;
  Bool caught;
  MemSet(probe_ptrs,0,sizeof(probe_ptrs));
  for (i=1;i<=4 && startup;i++) {
    probe_allocs=0;probe_fail=i;
    HolyCraft;
    ProbeEmpty;
    ProbeChk(old_draw==Fs->draw_it && old_inhibit==Fs->win_inhibit &&
	  old_settings==Fs->next_settings);
    CleanUp;
    ProbeEmpty;
    probe_cases++;
  }
  task=CAlloc(sizeof(CTask));
  dc=DCNew(160,96);
  for (i=1;i<=3;i++) {
    probe_fail=0;
    Init;
    SkyRowsMake;
    task->pix_width=64;task->pix_height=48;
    DrawIt(task,dc);
    ProbeChk(probe_live==7);
    old_view=g_view;old_depth=g_depth;old_left=g_left;
    old_depthcap=g_depthcap;old_edgecap=g_edgecap;
    task->pix_width=160;task->pix_height=96;
    probe_allocs=0;probe_fail=i;caught=FALSE;
    try
      DrawIt(task,dc);
    catch {
      ProbeChk(Fs->except_ch=='Alloc');
      Fs->catch_except=TRUE;
      caught=TRUE;
    }
    ProbeChk(caught && probe_live==7 && g_left==old_left &&
	  g_edgecap==old_edgecap);
    if (i==1) ProbeChk(g_view==old_view);
    if (i<=2)
      ProbeChk(g_depth==old_depth && g_depthcap==old_depthcap);
    probe_fail=0;
    DrawIt(task,dc);
    ProbeChk(probe_live==7 && g_depthcap>=160*96 && g_edgecap>=96 &&
	  g_view->width==160 && g_view->height==96 && !g_view->depth_buf);
    CleanUp;
    ProbeEmpty;
    CleanUp;
    ProbeEmpty;
    probe_cases++;
  }
  Free(task);
  DCDel(dc);
  if (startup)
    for (i=0;i<2;i++) {
      probe_fail=0;
      Spawn(&ProbeExit,Fs);
      HolyCraft;
      ProbeEmpty;
      ProbeChk(old_draw==Fs->draw_it && old_inhibit==Fs->win_inhibit &&
	    old_settings==Fs->next_settings);
    }
  "Lifetime:%d faults, clean retries\n",probe_cases;
}

LifetimeProbe;
