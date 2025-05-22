#include <stdint.h>
#include <stdio.h>

DEFINITIONS

static cell_t mem[MEMSIZE];
static cell_t *c = mem + INITIAL_CELL;

static inline void read(cell_t *c)
{
	int r = getc(stdin);
	if (r < 0)
		return;
	*c = (unsigned char)r;
}

static inline void print(cell_t c)
{
	(void)putc((unsigned char)c, stdout);
}

int main()
{
	PROGRAM
	return 0;
}
