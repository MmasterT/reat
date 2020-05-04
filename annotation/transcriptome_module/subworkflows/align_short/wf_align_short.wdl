version 1.0

import "../common/structs.wdl"
import "../common/rt_struct.wdl"
import "../common/tasks.wdl"

workflow wf_align_short {
    input {
        Array[PRSample] samples
        File reference_genome
        File? reference_annotation
        String aligner = "hisat"
        RuntimeAttr? alignment_resources
        RuntimeAttr? sort_resources
        RuntimeAttr? stats_resources
    }
    
    parameter_meta {
        samples: "Paired short read samples, each item is defined by a biological replicate name with one or more technical replicates. Technical replicates are defined by a name, R1, R2 and strand."
        reference_genome: "Genomic reference for read alignment."
        reference_annotation: "Use a reference annotation to guide the short read alignments."
        aligner: "Program used for alignment, current options are: hisat and star."
        alignment_resources: "Computational resources for alignment, overrides defaults."
        sort_resources: "Computational resources for sorting aligned BAMs, overrides defaults."
        stats_resources: "Computational resources for stats, overrides defaults."
    }

    if (defined(reference_annotation)) {
        call Hisat2SpliceSites {
            input: annotation = reference_annotation
        }
    }

    if (aligner == "hisat") {
        call tasks.Hisat2Index {
            input: reference = reference_genome
        }

        if (defined(Hisat2SpliceSites.sites)) {
            scatter (sample in samples) {
                scatter(PR in sample.read_pair) {
                    call Hisat as nopt{
                        input:
                        sites = Hisat2SpliceSites.sites,
                        strand = sample.strand,
                        name = sample.name,
                        sample = PR,
                        index = Hisat2Index.index,
                        runtime_attr_override = alignment_resources
                    }
                }
                AlignedSample hisat_aligned_sample = object {bam: nopt.bam, strand: sample.strand, aligner: "hisat", name: sample.name}
            }
        }
        if (!defined(Hisat2SpliceSites.sites)) {
            scatter (sample in samples) {
               scatter(PR in sample.read_pair) {
                   call Hisat as wopt {
                       input:
                       strand = sample.strand,
                       name = sample.name,
                       sample = PR,
                       index = Hisat2Index.index,
                       runtime_attr_override = alignment_resources
                   }
               }
               AlignedSample hisat_aligned_sample_no_sites = object {bam: wopt.bam, strand: sample.strand, aligner: "hisat", name: sample.name}
            }
        }
        Array[AlignedSample] def_hisat_aligned = select_first([hisat_aligned_sample, hisat_aligned_sample_no_sites])
    }

    if (aligner == "star") {
        call tasks.StarIndex {
            input:
            reference = reference_genome
        }
        scatter (sample in samples) {
            scatter(PR in sample.read_pair) {
                call Star {
                    input:
                    reference_annotation = reference_annotation,
                    strand = sample.strand,
                    name = sample.name,
                    sample = PR,
                    index = StarIndex.index,
                    runtime_attr_override = alignment_resources
                }
            }
            AlignedSample star_aligned_sample = object { bam: Star.aligned_pair, name: sample.name, strand: sample.strand, aligner: "star" }
        }
    }

    Array[AlignedSample] def_aligned_samples = select_first([def_hisat_aligned, star_aligned_sample])

    scatter (aligned_sample in def_aligned_samples) {
        scatter (bam in aligned_sample.bam) {
            call Sort {
                input:
                bam = bam,
                runtime_attr_override = sort_resources
            }
        }
        AlignedSample sorted_aligned_sample = object {name: aligned_sample.name, strand: aligned_sample.strand, aligner: aligned_sample.aligner, bam: Sort.sorted_bam}
    }

    scatter (aligned_sample in def_aligned_samples) {
        scatter (bam in aligned_sample.bam) {
            call Stats {
                input:
                bam = bam,
                runtime_attr_override = stats_resources
            }
        }
    }

    output {
        # Array[IndexedAlignedSample] indexed_aligned_samples = indexed_aligned_sample
        Array[AlignedSample] aligned_samples = sorted_aligned_sample
        Array[Array[File]] stats = Stats.stats
        Array[Array[Array[File]]] plots = Stats.plots
    }
}

task Sort{
    input {
        File bam
        String name = basename(bam, ".bam")
        RuntimeAttr? runtime_attr_override
    }

    Int cpus = 8

    output {
        IndexedBam indexed_bam = object { bam: name + ".sorted.bam", index: name + ".sorted.bam.bai" }
        File sorted_bam = name + ".sorted.bam"
    }

    command <<<
        set -euxo pipefail
        samtools sort -@~{cpus} ~{bam} > ~{name + ".sorted.bam"}
        samtools index ~{name + ".sorted.bam"}
    >>>

    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 16,
        max_retries: 1
    }
    
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])


    runtime {
        cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
    }
}

task Stats {
    input {
        File bam
        String name = basename(bam, ".bam")
        RuntimeAttr? runtime_attr_override
    }

    output {
        File stats = name + ".stats"
        Array[File] plots = glob("plot/*.png")
    }

    command <<<
        set -euxo pipefail
        samtools stats ~{bam} > ~{name + ".stats"} && \
        plot-bamstats -p "plot/~{name}" ~{name + ".stats"}
    >>>
    
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
}

task GSnapSpliceSites {
    input {
        File? annotation
        RuntimeAttr? runtime_attr_override
    }
    
    output {
        File sites = "gsnapSplicesites.iit"
    }

    command <<<
        set -euxo pipefail
        gtf_splicesites ~{annotation} | iit_store -o gsnapSplicesites.iit
    >>>

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
}

task Hisat2SpliceSites {
    input {
        File? annotation
        RuntimeAttr? runtime_attr_override
    }
    
    output {
        File sites = "hisat2Splicesites.txt"
    }

    command <<<
        set -euxo pipefail
        hisat2_extract_splice_sites.py ~{annotation} > "hisat2Splicesites.txt"
    >>>

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
}

task Hisat {
    input {
        Array[File] index
        File? sites
        ReadPair sample
        String strand
        String name
        String rp_name = name+"."+basename(sample.R1)
        RuntimeAttr? runtime_attr_override
    }

    Int cpus = 8
    
    output {
        File bam = rp_name + ".hisat.bam"
    }

    command <<<
        set -euxo pipefail
        strandness=""
        case "~{strand}" in
            fr-firststrand)
            strandness="--rna-strandness=RF"
            ;;
            fr-secondstrand)
            strandness="--rna-strandness=FR"
            ;;
            f)
            strandness="--rna-strandness=F"
            ;;
            r)
            strandness="--rna-strandness=R"
            ;;
        esac
    hisat2 -p ~{cpus} -x ~{sub(index[0], "\\.\\d\\.ht2l?", "")} \
    ${strandness} \
    --min-intronlen=20 \
    --max-intronlen=2000 \
    ~{"--known-splicesite-infile " + sites} \
    -1 ~{sample.R1} ~{"-2 " + sample.R2} | samtools sort -@ 4 - > "~{rp_name}.hisat.bam"
    >>>

    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 16,
        max_retries: 1
    }
    
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])


    runtime {
        cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
    }
}

task Star {
    input {
        Array[File] index
        File? reference_annotation
        ReadPair sample
        String strand
        String name
        String rp_name = name+"."+basename(sample.R1)
        RuntimeAttr? runtime_attr_override
    }

    Int cpus = 8
    
    output {
        File aligned_pair = rp_name + ".star.bam"
    }

    command <<<
        set -euxo pipefail
        r1_file=~{sample.R1}
        r1_ext=${r1_file##*.}
        compression=""
        case "${r1_ext}" in
            gz)
            compression="--readFilesCommand \"gzip -dc\""
            ;;
            bz | bz2)
            compression="--readFilesCommand \"bzip2 -dc\""
            ;;
        esac

            STAR --genomeDir "$(dirname ~{index[0]})" \
    --runThreadN ~{cpus} \
    "${compression}" \
    --runMode alignReads \
    --outSAMtype BAM Unsorted \
    --outSAMattributes NH HI AS nM XS NM MD --outSAMstrandField intronMotif \
    --alignIntronMin 20 \
    --alignIntronMax 2000 \
    --alignMatesGapMax 2000 \
    ~{"--sjdbGTFfile " + reference_annotation} \
    --readFilesIn ~{sample.R1} ~{sample.R2} && ln -s Aligned.out.bam "~{rp_name}.star.bam"
    >>>

    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 16,
        max_retries: 1
    }
    
    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])


    runtime {
        cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
    }
}