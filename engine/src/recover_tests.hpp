#pragma once
// Only our own test allocation and process are touched.
int test_recovery() {
    constexpr SIZE_T bytes=64*1024*1024;
    auto memory=static_cast<unsigned char*>(VirtualAlloc(nullptr,bytes,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
    if(!memory)throw std::runtime_error("Recovery fixture allocation failed");
    struct Free { void* p; ~Free() { VirtualFree(p,0,MEM_RELEASE); } } release{memory};
    for(SIZE_T i=0;i<bytes;i+=4096)memory[i]=static_cast<unsigned char>((i/4096)%251);
    CountersEx2 before{},after{};
    if(!read_memory(GetCurrentProcess(),before))throw std::runtime_error("Recovery fixture memory unavailable");
    if(!EmptyWorkingSet(GetCurrentProcess()))throw std::runtime_error("EmptyWorkingSet failed on own fixture");
    if(!read_memory(GetCurrentProcess(),after))throw std::runtime_error("Recovery fixture after read failed");
    // Commit and data must remain: lower residency must never mean discarded data.
    if(after.base.PrivateUsage+ame::MiB<before.base.PrivateUsage)throw std::runtime_error("Unexpected fixture commit decrease");
    if(after.private_ws>=before.private_ws)throw std::runtime_error("Own fixture did not reduce resident memory");
    for(SIZE_T i=0;i<bytes;i+=4096)if(memory[i]!=static_cast<unsigned char>((i/4096)%251))throw std::runtime_error("Fixture data changed");
    if(GetCurrentProcessId()==0)throw std::runtime_error("Fixture process identity lost");
    std::cout<<"PASS own-process resident trim, private residency reduction, data preserved, allocation retained\n";
    return 0;
}
