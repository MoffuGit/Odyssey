pub const Atlas = @import("datastruct/atlas.zig");
pub const btree = @import("datastruct/btree.zig");
pub const doubly_linked_list = @import("datastruct/doubly_linked_list.zig");
pub const DoublyLinkedList = doubly_linked_list.DoublyLinkedList;
pub const heap = @import("datastruct/heap.zig");
pub const linked_list = @import("datastruct/linked_list.zig");
pub const SinglyLinkedList = linked_list.SinglyLinkedList;
pub const mem_map = @import("datastruct/memory_map.zig");
pub const mpsc = @import("datastruct/mpsc.zig");
pub const MpscBounded = mpsc.MpscBounded;
pub const Mpsc = mpsc.Mpsc;
pub const slotmap = @import("datastruct/slotmap.zig");
pub const spsc = @import("datastruct/spsc.zig");
pub const SpscBounded = spsc.SpscBounded;
pub const SwapChain = @import("datastruct/swap_chain.zig").SwapChain;
pub const tagged_linked_list = @import("datastruct/tagged_linked_list.zig");
pub const TaggedLinkedList = tagged_linked_list.TaggedLinkedList;

test {
    _ = Atlas;
    _ = SwapChain;
    _ = mpsc;
    _ = spsc;
    _ = mem_map;
    _ = linked_list;
    _ = doubly_linked_list;
    _ = heap;
    _ = slotmap;
    _ = btree;
    _ = tagged_linked_list;
}
