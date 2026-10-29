#include "../src/resource_trace.hpp"
#include <iostream>

// Generates only synthetic observations, for the report/serialization tests.
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    try {
        ame::resource::Trace trace;
        trace.open(std::filesystem::u8path(argv[1]), "synthetic_test");
        trace.phase("identity");
        trace.call("AmeAttachProcess(group, identity) <script>alert(\"x\")</script>\n\t", AME_IDENTITY_CHANGED, 0);
        trace.check("wrong identity refused: \"quote\" \\ slash\nnew line", true);
        trace.process(42, 134000000000000000ull);
        AmeGroupSnapshot before{}; before.size = sizeof(before); before.flags = AME_MEMORY_COMPLETE;
        before.active_processes = 1; before.measured_processes = 1;
        before.private_commit_sum_bytes = 8 * 1048576ull; before.working_set_sum_bytes = 10 * 1048576ull;
        trace.snapshot("before_growth", 1, before);
        trace.phase("memory_notice");
        auto after = before; after.private_commit_sum_bytes = 72 * 1048576ull;
        after.working_set_sum_bytes = 74 * 1048576ull; after.commit_notice_bytes = 32 * 1048576ull;
        after.flags |= AME_RATES_VALID; after.cpu_percent_machine = 1.25;
        after.page_faults_per_second = 2.5; after.rate_interval_ms = 2000;
        trace.snapshot("after_growth", 1, after);
        AmeGroupEvent event{}; event.size = sizeof(event); event.kind = AME_EVENT_COMMIT_NOTICE;
        event.windows_message = 11; event.job_commit_bytes = 72 * 1048576ull;
        event.commit_notice_bytes = 32 * 1048576ull;
        trace.event(1, event);
        trace.finish(true, 1);
        if (!trace.healthy()) return 1;
        std::cout << "PASS synthetic trace fixture generated\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
