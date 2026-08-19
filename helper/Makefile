#!/usr/bin/make -f

# -mno-red-zone: the inline SMM asm pushes to the stack, which would
# otherwise land in the 128-byte red zone the ABI lets gcc use
CFLAGS ?= -O2 -Wall -Wextra -mno-red-zone

all: dell-bios-fan-control

dell-bios-fan-control: dell-bios-fan-control.c
	$(CC) $(CFLAGS) -o $@ $^

clean:
	rm -f dell-bios-fan-control
