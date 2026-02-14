OUTPUT_ARCH(elf64-littleriscv)
ENTRY(start);

KERNEL_ADDRESS = 0x80200000;
STACK_SIZE = 0x10000;

PHDRS {
	text PT_LOAD ;
	data PT_LOAD ;
	rodata PT_LOAD ;
	bss PT_LOAD ;
}

SECTIONS {
	. = KERNEL_ADDRESS;
	PROVIDE(__kernel_start = .);

	.text : ALIGN(4K) {
		PROVIDE(__text_start = .);
		*(.init);
		*(.text);
		*(.text*);
		PROVIDE(__text_end = .);
	} :text

	.rodata : ALIGN(4K) {
		PROVIDE(__rodata_start = .);
		*(.rodata);
		*(.rodata*);
		PROVIDE(__rodata_end = .);
	} :rodata

	PROVIDE(__global_pointer = .);

	.data : ALIGN(4K) {
		PROVIDE(__data_start = .);
		*(.data);
		*(.data*);
		*(.sdata);
		PROVIDE(__data_end = .);
	} :data

	.bss : ALIGN(4K) {
		PROVIDE(__bss_start = .);
		*(.bss);
		*(.bss*);
		*(.sbss);
		PROVIDE(__bss_end = .);
	} :bss

	.stack(NOLOAD) : ALIGN(4K) {
		PROVIDE(__stack_start = .);
		. += STACK_SIZE;
		PROVIDE(__stack_top = .);
		PROVIDE(__stack_end = .);
	} :bss

	PROVIDE(__kernel_end = .);
}
