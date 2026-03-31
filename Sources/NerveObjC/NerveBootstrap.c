#if DEBUG

extern void nerve_framework_init(void);

__attribute__((constructor))
static void nerve_bootstrap(void) {
    nerve_framework_init();
}

#endif
