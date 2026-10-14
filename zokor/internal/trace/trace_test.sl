fn test_state_is_ordered_bounded_and_rejects_duplicate_keys() {
    assert(state(" vendor=one , 1tenant@system=two ", 512, 32) == "vendor=one,1tenant@system=two");
    assert(state("a=one,a=two", 512, 32) == "");
    assert(state("a=one,b=two", 512, 1) == "");
    assert(state("a=one", 4, 32) == "");
    assert(state("Upper=one", 512, 32) == "");
    assert(state("a=bad=value", 512, 32) == "");
}

fn test_state_accepts_empty_members_and_preserves_vendor_value_spaces() {
    assert(state(" ,vendor= one , ,other=two,", 512, 32) == "vendor= one,other=two");
    assert(state("vendor =one", 512, 32) == "");
    assert(state("vendor=\tone", 512, 32) == "");
    assert(state("\nvendor=one", 512, 32) == "");
    assert(state("vendor=one\r", 512, 32) == "");
}
