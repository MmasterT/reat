version 1.0

struct RuntimeAttr {
    String? constraints
    String? queue
    Float? mem_gb
    Int? cpu_cores
    Int? disk_gb
    Int? boot_disk_gb
    Int? preemptible_tries
    Int? max_retries
}
