const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
});

pub usingnamespace c;

const has_decorations = @hasDecl(c, "xdg_toplevel_set_decorations");

pub fn xdg_toplevel_set_decorations(toplevel: *c.xdg_toplevel, decorations: u32) void {
    if (has_decorations) {
        c.xdg_toplevel_set_decorations(toplevel, decorations);
    }
}
