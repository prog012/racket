/* >>>> Generated by mkmark.rkt from mzmarksrc.c <<<< */

static int mark_finalization_SIZE(void *p, struct NewGC *gc) {
  return
  gcBYTES_TO_WORDS(sizeof(Finalization));
}

static int mark_finalization_MARK(void *p, struct NewGC *gc) {
  Finalization *f = (Finalization *)p;
  
  gcMARK2(f->data, gc);
  gcMARK2(f->next, gc);
  gcMARK2(f->prev, gc);

  return
  gcBYTES_TO_WORDS(sizeof(Finalization));
}

static int mark_finalization_FIXUP(void *p, struct NewGC *gc) {
  Finalization *f = (Finalization *)p;
  
  gcFIXUP2(f->data, gc);
  gcFIXUP2(f->next, gc);
  gcFIXUP2(f->prev, gc);

  return
  gcBYTES_TO_WORDS(sizeof(Finalization));
}

#define mark_finalization_IS_ATOMIC 0
#define mark_finalization_IS_CONST_SIZE 1


static int mark_finalizations_SIZE(void *p, struct NewGC *gc) {
  return
  gcBYTES_TO_WORDS(sizeof(Finalizations));
}

static int mark_finalizations_MARK(void *p, struct NewGC *gc) {
  Finalizations *f = (Finalizations *)p;

  gcMARK2(f->scheme_first, gc);
  gcMARK2(f->scheme_last, gc);
  gcMARK2(f->prim_first, gc);
  gcMARK2(f->prim_last, gc);
  gcMARK2(f->ext_data, gc);

  return
  gcBYTES_TO_WORDS(sizeof(Finalizations));
}

static int mark_finalizations_FIXUP(void *p, struct NewGC *gc) {
  Finalizations *f = (Finalizations *)p;

  gcFIXUP2(f->scheme_first, gc);
  gcFIXUP2(f->scheme_last, gc);
  gcFIXUP2(f->prim_first, gc);
  gcFIXUP2(f->prim_last, gc);
  gcFIXUP2(f->ext_data, gc);

  return
  gcBYTES_TO_WORDS(sizeof(Finalizations));
}

#define mark_finalizations_IS_ATOMIC 0
#define mark_finalizations_IS_CONST_SIZE 1


