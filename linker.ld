OUTPUT_ARCH(elf64-littleriscv)
ENTRY(start);

KERNEL_ADDRESS = 0x80200000;
STACK_SIZE = 0x10000;

DEBUG_SECTION_ALIGN = 8;

RX_REGION_SIZE = 4M;
RW_REGION_SIZE = 2M;
RO_REGION_SIZE = 2M;

RX_REGION_START = KERNEL_ADDRESS;
RW_REGION_START = RX_REGION_START + RX_REGION_SIZE;
RO_REGION_START = RW_REGION_START + RW_REGION_SIZE;

MEMORY {
	ram_rx (rx) : ORIGIN = RX_REGION_START, LENGTH = RX_REGION_SIZE
	ram_rw (rw) : ORIGIN = RW_REGION_START, LENGTH = RW_REGION_SIZE
	ram_ro (r)  : ORIGIN = RO_REGION_START, LENGTH = RO_REGION_SIZE
}

PHDRS {
	text PT_LOAD ;
	data PT_LOAD ;
	rodata PT_LOAD ;
	bss PT_LOAD ;
}

SECTIONS {
	. = KERNEL_ADDRESS;
	__kernel_start = .;

	.text : ALIGN(4K) {
		__text_start = .;
		*(.init);
		*(.text);
		*(.text*);
		__text_end = .;
	} > ram_rx :text

	.rodata : ALIGN(4K) {
		__rodata_start = .;
		*(.rodata);
		*(.rodata*);

		. = ALIGN(DEBUG_SECTION_ALIGN);

		/* __debug_info_start = .; */
		/* KEEP(*(.debug_info)); */
		/* __debug_info_end = .; */
		/**/
		/* . = ALIGN(DEBUG_SECTION_ALIGN); */
		/**/
		/* __debug_abbrev_start = .; */
		/* KEEP(*(.debug_abbrev)); */
		/* __debug_abbrev_end = .; */
		/**/
		/* . = ALIGN(DEBUG_SECTION_ALIGN); */
		/**/
		/* __debug_str_start = .; */
		/* KEEP(*(.debug_str)); */
		/* __debug_str_end = .; */
		/**/
		/* . = ALIGN(DEBUG_SECTION_ALIGN); */
		/**/
		/* __debug_ranges_start = .; */
		/* KEEP(*(.debug_ranges)); */
		/* __debug_ranges_end = .; */
		/**/
		/* . = ALIGN(DEBUG_SECTION_ALIGN); */
		/**/
		/* __debug_line_start = .; */
		/* KEEP(*(.debug_line)); */
		/* __debug_line_end = .; */
		/**/
		/* . = ALIGN(DEBUG_SECTION_ALIGN); */
		/**/
		/* __debug_frame_start = .; */
		/* KEEP(*(.debug_frame)); */
		/* __debug_frame_end = .; */
		/**/
		__rodata_end = .;
	} > ram_ro :rodata

	/* TODO: related to the issue linked in debug.zig */
  /* .rodata declaration consumes .debug_info and others */
	.debug_info : {
		KEEP(*(.debug_info));
	}

	.debug_abbrev : {
		KEEP(*(.debug_abbrev));
	}

	.debug_str : {
		KEEP(*(.debug_str));
	}

	.debug_range : {
		KEEP(*(.debug_range));
	}
	
	.debug_line : {
		KEEP(*(.debug_line));
	}

	.debug_frame : {
		KEEP(*(.debug_frame));
	}

	__global_pointer = .;

	.data : ALIGN(4K) {
		__data_start = .;
		*(.data);
		*(.data*);
		*(.sdata);
		__data_end = .;
	} > ram_rw :data

	.bss : ALIGN(4K) {
		__bss_start = .;
		*(.bss);
		*(.bss*);
		*(.sbss);
		__bss_end = .;
	} > ram_rw :bss

	.stack(NOLOAD) : ALIGN(4K) {
		__stack_start = .;
		. += STACK_SIZE;
		__stack_top = .;
		__stack_end = .;
	} > ram_rw :bss

	__kernel_end = .;
}
