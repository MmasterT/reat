version 1.0

import "../common/structs.wdl"
import "../common/rt_struct.wdl"

workflow wf_assembly_long {
    input {
        File? reference_annotation
        Array[AlignedSample] aligned_samples
        String assembler = "None"
    }

    scatter (sample in aligned_samples) {
        if (assembler == "None") {
            call sam2gff {
                input:
                aligned_sample = sample
            }
        }
        if (assembler == "merge") {
            call gffread_merge {
                input:
                aligned_sample = sample
            }
        }

        if (assembler == "stringtie") {
            call stringtie_long {
                input:
                reference_annotation = reference_annotation,
                aligned_sample = sample
            }
        }
        File def_gff = select_first([sam2gff.gff, gffread_merge.gff, stringtie_long.gff])
    }

    output {
        Array[File] gff = def_gff
    }

}

task stringtie_long {
    input {
        File? reference_annotation
        AlignedSample aligned_sample
        RuntimeAttr? runtime_attr_override
    }
    
    RuntimeAttr default_attr = object {
        cpu_cores: 1,
        mem_gb: 4,
        max_retries: 1
    }
    
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])


  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }

    output {
        File gff = "result.gff"
    }

    command <<<
    stringtie -p 4 ~{"-G " + reference_annotation} -L ~{aligned_sample.bam} -o "result.gff"
    >>>
}

task sam2gff {
    input {
        AlignedSample aligned_sample
        RuntimeAttr? runtime_attr_override
    }
    
    RuntimeAttr default_attr = object {
        cpu_cores: 1,
        mem_gb: 4,
        max_retries: 1
    }
    
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])


  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }

    output {
        File gff = "result.gff"
    }

    command <<<
    samtools view -F 4 -F 0x900 ~{aligned_sample.bam} | sam2gff -s ~{aligned_sample.name} > result.gff
    >>>
}

task gffread_merge {
    input {
        AlignedSample aligned_sample
        RuntimeAttr? runtime_attr_override
    }
    
    RuntimeAttr default_attr = object {
        cpu_cores: 1,
        mem_gb: 4,
        max_retries: 1
    }
    
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])


  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }

    output {
        File gff = "result.gff"
    }

    command <<<
    samtools view -F 4 -F 0x900 ~{aligned_sample.bam} | sam2gff -s ~{aligned_sample.name} | gffread -T -M -K -o result.gff
    >>>
}