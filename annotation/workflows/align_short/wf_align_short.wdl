version 1.0

import "../structs/structs.wdl"

workflow wf_align_short {
    input {
        Array[PRSample] samples
        File? annotation
        Array[File] gsnap_index
        Array[File] hisat_index
        Array[File] star_index
    }

    if (defined(annotation)) {
        call hisat2SpliceSites {
            input: annotation = annotation
        }
    }

    call Hisat {
        input:
        sites = hisat2SpliceSites.sites,
        sample = samples[0],
        index = hisat_index
    }

    call Star {
        input:
        annotation = annotation,
        sample = samples[0],
        index = star_index
    }

    Array[File] bams = [Hisat.bam, Star.bam]

    scatter (bam in bams) {
        call Sort {
            input:
            bam = bam
        }
    }

    scatter (bam in bams) {
        call Stats {
            input:
            bam = bam
        }
    }

    output {
        Array[Pair[File,File]] indexed_bams = Sort.indexed_bam
        Array[File] stats = Stats.stats
        Array[Array[File]] plots = Stats.plots
    }
}

task Sort{
    input {
        File bam
        String name = basename(bam, ".bam")
    }

    output {
        Pair[File,File] indexed_bam = (name + ".sorted.bam", name + ".sorted.bam.bai")
    }

    command <<<
        samtools sort ~{bam} > ~{name + ".sorted.bam"}
        samtools index ~{name + ".sorted.bam"}
    >>>
}

task Stats {
    input {
        File bam
        String name = basename(bam, ".bam")
    }

    output {
        File stats = name + ".stats"
        Array[File] plots = glob("plot/*.png")
    }

    command <<<
        samtools stats ~{bam} > ~{name + ".stats"} && \
        plot-bamstats -p plot/ ~{name + ".stats"}
    >>>
}

task GSnapSpliceSites {
    input {
        File? annotation
    }

    output {
        File sites = "gsnapSplicesites.iit"
    }

    command <<<
        gtf_splicesites ~{annotation} | iit_store -o gsnapSplicesites.iit
    >>>
}

task hisat2SpliceSites {
    input {
        File? annotation
    }

    output {
        File sites = "hisat2Splicesites.txt"
    }

    command <<<
        hisat2_extract_splice_sites.py ~{annotation} > "hisat2Splicesites.txt"
    >>>
}

task GSnap {
    input {
        Array[File] index
        File? sites
        PRSample sample
    }

    output {
        File bam = "gsnap.bam"
    }

    command <<<
        r1_file=~{sample.R1}
        r1_ext=${r1_file##*.}
        compression=""
        case "${r1_ext}" in
            gz)
            compression="${compression}--gunzip"
            ;;
            bz | bz2)
            compression="${compression}--bunzip2"
            ;;
        esac
        gsnap --nthreads 4 --dir="$(dirname "~{index[0]}")" \
        --db=ref \
        --novelsplicing=1 \
        ${compression} \
        ~{"-s " + sites} \
        --localsplicedist=2000 \
        --format=sam --npaths=20 \
        ~{sample.R1} ~{sample.R2} | samtools sort -@ 4 - > "gsnap.bam"
    >>>

}

task Hisat {
    input {
        Array[File] index
        File? sites
        PRSample sample
        String strand = "fr-firststrand"
    }

    output {
        File bam = "hisat.bam"
    }

    command <<<
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
    hisat2 -p 4 -x ~{sub(index[0], "\\.\\d\\.ht2l?", "")} \
    ${strandness} \
    --min-intronlen=20 \
    --max-intronlen=2000 \
    ~{"--known-splicesite-infile " + sites} \
    -1 ~{sample.R1} ~{"-2 " + sample.R2} | samtools sort -@ 4 - > "hisat.bam"
    >>>
}

task Star {
    input {
        Array[File] index
        File? annotation
        PRSample sample
    }

    output {
        File test_ok = "Aligned.out.bam"
        File bam = "star.bam"
    }

    command <<<
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
    --runThreadN 4 \
    "${compression}" \
    --runMode alignReads \
    --outSAMtype BAM Unsorted \
    --outSAMattributes NH HI AS nM XS NM MD --outSAMstrandField intronMotif \
    --alignIntronMin 20 \
    --alignIntronMax 2000 \
    --alignMatesGapMax 2000 \
    ~{"--sjdbGTFfile " + annotation} \
    --readFilesIn ~{sample.R1} ~{sample.R2} && ln -s Aligned.out.bam star.bam
    >>>
}

task Tophat {
    input {
        Array[File] index
        PRSample sample
        File? annotation
        String strand
    }

    output {
        File bam = "tophat2_accepted.bam"
    }

    command <<<
        tophat2 \
        --num-threads 4 \
        --library-type=~{strand} \
        --min-intron-length=20 \
        --max-intron-length=2000 \
        ~{"--GTF " + annotation} \
        ~{sub(index[0], "\\.\\d\\.bt2l?", "")} \
        ~{sample.R1} ~{sample.R2} && ln -s tophat_out/accepted_hits.bam tophat2_accepted.bam
    >>>
}
