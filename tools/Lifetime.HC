I64 probe_fail=0,probe_allocs=0,probe_live=0,probe_cases=0;
U8 *probe_ptrs[32];

U0 ProbeChk(Bool ok)
{
  if (!ok) throw('Lifetime',TRUE);
}

U0 ProbeAlloc()
{
  if (++probe_allocs==probe_fail) throw('Alloc',TRUE);
}

U8 *ProbeKeep(U8 *ptr)
{
  I64 i;
  for (i=0;i<32;i++)
    if (!probe_ptrs[i]) {
      probe_ptrs[i]=ptr;
      probe_live++;
      return ptr;
    }
  throw('Full',TRUE);
}

U0 ProbeDrop(U8 *ptr)
{
  I64 i;
  if (!ptr) return;
  for (i=0;i<32;i++)
    if (probe_ptrs[i]==ptr) {
      probe_ptrs[i]=NULL;
      probe_live--;
      return;
    }
  throw('BadFree',TRUE);
}

U8 *ProbeMAlloc(I64 size)
{
  ProbeAlloc;
  return ProbeKeep(MAlloc(size));
}

U0 ProbeFree(U8 *ptr)
{
  ProbeDrop(ptr);
  Free(ptr);
}

CDC *ProbeDCNew(I64 w,I64 h)
{
  ProbeAlloc;
  return ProbeKeep(DCNew(w,h));
}

CDC *ProbeDCAlias()
{
  ProbeAlloc;
  return ProbeKeep(DCAlias);
}

U0 ProbeDCDel(CDC *dc)
{
  ProbeDrop(dc);
  DCDel(dc);
}
