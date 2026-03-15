OUTPUT_ARCH(elf64-littleriscv)
ENTRY(start);

KERNEL_PHYS_ADDRESS = 0x80200000;
KERNEL_VIRT_ADDRESS = 0xffffffffc0200000;
KERNEL_VIRT_START = 0xffffffffc0200000 - KERNEL_PHYS_ADDRESS;
KERNEL_OFFSET = KERNEL_VIRT_ADDRESS - KERNEL_PHYS_ADDRESS;
STACK_SIZE = 0x10000;

SECTIONS {
	. = KERNEL_PHYS_ADDRESS;

	.lh_text : ALIGN(4K) {
		*phys_start.o(.text*);
	} 

	.lh_data : ALIGN(4K) {
		*phys_start.o(.data*);
	}

	. += KERNEL_OFFSET;
	
	.text : AT(ADDR(.text) - KERNEL_VIRT_START) ALIGN(4K) {
		__kernel_start = .;
		__text_start = .;
		*(.text);
		*(.text*);
		__text_end = .;
	} :text

	.rodata : AT(ADDR(.rodata) - KERNEL_VIRT_START) ALIGN(4K) {
		__rodata_start = .;

		*(.rodata)
		*(.rodata*);
		*(.eh_frame*);

		__rodata_end = .;
	} :rodata

	__global_pointer = .;

	.data : AT(ADDR(.data) - KERNEL_VIRT_START) ALIGN(4K) {
		__data_start = .;
		*(.data);
		*(.data*);
		*(.sdata);
		__data_end = .;
	} :data

	.bss : AT(ADDR(.bss) - KERNEL_VIRT_START) ALIGN(4K) {
		__bss_start = .;
		*(.bss);
		*(.bss*);
		*(.sbss);
		__bss_end = .;
	} :bss

  .shstrtab :
  {
    *(.shstrtab)
  }

	__kernel_end = .;

	/DISACRD/ : {

	}
}
