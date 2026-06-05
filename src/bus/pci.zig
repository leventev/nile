//! https://docs.zephyrproject.org/latest/build/dts/api/bindings/pcie/host/pci-host-ecam-generic.html
//! https://elixir.bootlin.com/linux/v7.0/source/Documentation/devicetree/bindings/pci/host-generic-pci.yaml

const root = @import("root");
const devicetree = root.devicetree;

pub fn initDriver(dt: *const devicetree.DeviceTree, handle: u32) !void {
    const node = dt.nodes.items[handle];

    const ranges = node.getProperty(.ranges) orelse
        @panic("Devicetree PCI node is required to contain .ranges field");
    const reg = node.getProperty(.reg) orelse
        @panic("Devicetree PCI node is required to contain .reg field");

    _ = ranges;
    _ = reg;
    // ranges.
    devicetree.printDeviceTree("pci/", dt, handle, 0);
}
