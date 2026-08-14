#!/usr/bin/make -f

CFLAGS ?= -O2 -Wall -Wextra

all: dell-bios-fan-control

dell-bios-fan-control: dell-bios-fan-control.c
	$(CC) $(CFLAGS) -o $@ $^

clean:
	rm -f dell-bios-fan-control
