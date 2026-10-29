#ifndef AME_RESOURCE_API_H
#define AME_RESOURCE_API_H

/* Windows 10/11 x64; C ABI, UTF-16 paths, default packing = 8. */
#include <stdint.h>
#include <stddef.h>
#if defined(_WIN32)
# if defined(AME_RESOURCE_API_EXPORTS)
#  define AME_API __declspec(dllexport)
# else
#  define AME_API __declspec(dllimport)
# endif
# define AME_CALL __cdecl
#else
# define AME_API
# define AME_CALL
#endif
#ifdef __cplusplus
extern "C" {
#endif

#define AME_RESOURCE_ABI_VERSION 1u
#define AME_RESOURCE_PATH_CAPACITY 32768u
#define AME_RESOURCE_MAX_GROUPS 16u
#define AME_RESOURCE_MAX_MEMBERS 64u
typedef uint64_t AmeGroup;
typedef enum AmeResult {
    AME_OK = 0,
    AME_INVALID_ARGUMENT = 1,
    AME_INVALID_GROUP = 2,
    AME_WINDOWS_ERROR = 3,
    AME_IDENTITY_CHANGED = 4,
    AME_PROCESS_EXCLUDED = 5,
    AME_ALREADY_MANAGED = 6,
    AME_CAPACITY_REACHED = 7,
    AME_NO_EVENT = 8
} AmeResult;

enum {
    AME_MEMORY_COMPLETE = 1u,
    AME_RATES_VALID = 2u,
    AME_COMMIT_NOTICE_EXCEEDED = 4u
};
typedef enum AmeEventKind {
    AME_EVENT_PROCESS_STARTED = 1,
    AME_EVENT_PROCESS_EXITED = 2,
    AME_EVENT_GROUP_EMPTY = 3,
    AME_EVENT_COMMIT_NOTICE = 4,
    AME_EVENT_OTHER = 5
} AmeEventKind;

#pragma pack(push, 8)
typedef struct AmeProcessIdentity {
    uint32_t size;
    uint32_t pid;
    uint64_t creation_filetime;
    wchar_t image_path[AME_RESOURCE_PATH_CAPACITY];
} AmeProcessIdentity;

typedef struct AmeGroupSnapshot {
    uint32_t size;
    uint32_t flags;
    uint64_t monotonic_ms;
    uint32_t attached_total;
    uint32_t active_processes;
    uint32_t measured_processes;
    uint32_t missing_processes;
    /* Sum of working sets: shared pages can be counted more than once. */
    uint64_t working_set_sum_bytes;
    uint64_t private_commit_sum_bytes;
    /* Lifetime job counters, including exited processes. I/O is not disk-only. */
    uint64_t cpu_time_100ns;
    uint64_t io_read_bytes;
    uint64_t io_write_bytes;
    uint64_t page_faults_total;
    uint64_t commit_notice_bytes;
    uint64_t membership_revision;
    uint64_t rate_interval_ms;
    double cpu_percent_machine;
    double io_read_bytes_per_second;
    double io_write_bytes_per_second;
    double page_faults_per_second;
    int64_t private_commit_change_bytes;
} AmeGroupSnapshot;

typedef struct AmeGroupEvent {
    uint32_t size;
    uint32_t kind;
    uint32_t pid;
    uint32_t windows_message;
    uint64_t monotonic_ms;
    uint64_t job_commit_bytes;
    uint64_t commit_notice_bytes;
    uint64_t policy_revision;
} AmeGroupEvent;

typedef enum AmeReclaimStage {
    AME_STAGE_COOPERATIVE_CACHE = 1u,
    AME_STAGE_MEMORY_PRIORITY = 2u,
    AME_STAGE_ECO_QOS = 4u,
    AME_STAGE_WORKING_SET_TRIM = 8u
} AmeReclaimStage;

typedef struct AmeReclaimResult {
    uint32_t size;
    uint32_t applied_stages;
    uint64_t monotonic_ms;
    uint64_t working_set_before_bytes;
    uint64_t working_set_after_bytes;
    uint64_t private_commit_before_bytes;
    uint64_t private_commit_after_bytes;
    int64_t working_set_delta_bytes;
    uint64_t cooperative_released_bytes;
} AmeReclaimResult;
#pragma pack(pop)

typedef uint64_t (AME_CALL *AmeInternalReclaimCallback)(uint64_t requested_bytes, void* context);

AME_API uint32_t AME_CALL AmeGetApiVersion(void);
/* Thread-local Win32 detail of the last AmeResult-returning call. */
AME_API uint32_t AME_CALL AmeGetLastWindowsError(void);
/* Read-only identity capture. Does not grant permission to mutate the process. */
AME_API AmeResult AME_CALL AmeReadProcessIdentity(uint32_t pid, AmeProcessIdentity* identity);
AME_API AmeResult AME_CALL AmeCreateGroup(AmeGroup* group);
/* CPU rate control: 0 disables; 1..100 sets maximum CPU percentage cap for the group. */
AME_API AmeResult AME_CALL AmeSetGroupCpuRate(AmeGroup group, uint32_t max_percent);
/* Explicit, persistent Windows job membership; no detach API exists.
   Requires the complete freshly captured identity. Existing jobs are refused.
   New children do NOT automatically enter this group. */
AME_API AmeResult AME_CALL AmeAttachProcess(AmeGroup group, const AmeProcessIdentity* identity);
/* 0 disables; otherwise 1 MiB..1 TiB. Notification only, not an allocation cap. */
AME_API AmeResult AME_CALL AmeSetCommitNotice(AmeGroup group, uint64_t bytes);
AME_API AmeResult AME_CALL AmeReadGroupSnapshot(AmeGroup group, AmeGroupSnapshot* snapshot);
/* Nonblocking; caller polls. Every AME_OK returns one real kernel message. */
AME_API AmeResult AME_CALL AmePollGroupEvent(AmeGroup group, AmeGroupEvent* event);
/* Releases AME monitoring; does not detach or terminate live members.
   Notification is cleared first. Retry on error; no stale ID reuse. */
AME_API AmeResult AME_CALL AmeCloseGroup(AmeGroup group);
/* Internal Windows cooperative & native memory reclamation APIs. */
AME_API AmeResult AME_CALL AmeRegisterInternalProcessHandler(AmeInternalReclaimCallback callback, void* context);
AME_API AmeResult AME_CALL AmeCompactCurrentProcess(uint64_t requested_bytes, uint64_t* released_bytes);
AME_API AmeResult AME_CALL AmeExecuteProcessReclaim(const AmeProcessIdentity* identity, uint32_t stage_flags, AmeReclaimResult* output);
AME_API AmeResult AME_CALL AmeReclaimGroupBudget(AmeGroup group, uint64_t target_reclaim_bytes, uint32_t stage_flags, uint64_t* total_reclaimed_bytes, uint32_t* affected_processes);
AME_API AmeResult AME_CALL AmeRestoreProcess(const AmeProcessIdentity* identity);
AME_API AmeResult AME_CALL AmeRestoreAllProcesses(uint32_t* restored_count);
/* Memory Compression observation and transient pressure pulse flush */
AME_API AmeResult AME_CALL AmeGetMemoryCompressionBytes(uint64_t* working_set_bytes);
AME_API AmeResult AME_CALL AmePulseFlushMemory(uint64_t target_pulse_bytes, uint64_t* freed_bytes);
/* Hybrid Technique A+B: Enforces hard working set quota (QUOTA_LIMITS_HARDWS_MAX_ENABLE)
   and sets selective compression memory priority (MEMORY_PRIORITY_LOW). */
AME_API AmeResult AME_CALL AmeClampProcessWorkingSet(const AmeProcessIdentity* identity, uint64_t max_bytes, AmeReclaimResult* output);
AME_API AmeResult AME_CALL AmeUnclampProcessWorkingSet(const AmeProcessIdentity* identity);

#ifdef __cplusplus
}
#endif
#endif
