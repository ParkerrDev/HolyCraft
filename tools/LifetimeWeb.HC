U0 LifetimeWeb()
{
  I64 i;
  MemSet(probe_ptrs,0,sizeof(probe_ptrs));
  for (i=1;i<=5;i++) {
    probe_allocs=0;probe_fail=i;
    HolyCraft;
    ProbeChk(!probe_live && !g_world && !g_hm && !g_lo && !g_fb &&
	  !BrowserMouseCapture);
    CleanUp;
    ProbeChk(!probe_live);
    probe_cases++;
  }
  probe_fail=0;
  HolyCraft;
  ProbeChk(!probe_live && !g_world && !g_hm && !g_lo && !g_fb &&
	!BrowserMouseCapture);
  "Lifetime:%d faults, clean retries\n",probe_cases;
}

LifetimeWeb;
