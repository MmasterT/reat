version 1.0

import "../common/structs.wdl"
import "./orf_caller/wf_transdecoder.wdl" as tdc
import "./homology/wf_homology.wdl" as hml

workflow wf_mikado {
    input {
        IndexedReference indexed_reference
        Array[AssembledSample]? SR_assemblies
        Array[AssembledSample]? LQ_assemblies
        Array[AssembledSample]? HQ_assemblies
        File scoring_file
        File orf_calling_proteins
        File homology_proteins
        File? extra_config
        File? junctions
        String gencode = "Universal"
        String orf_caller = "Transdecoder"
        Boolean mikado_do_homology_assessment = false
    }

    if (defined(SR_assemblies)) {
        Array[AssembledSample] def_SR_assemblies = select_first([SR_assemblies])
        scatter (sr_assembly in def_SR_assemblies) {
            call GenerateModelsList as sr_models {
                input:
                assembly = sr_assembly
            }
        }
    }

    if (defined(LQ_assemblies)) {
        Array[AssembledSample] def_LQ_assemblies = select_first([LQ_assemblies])

        scatter (lr_assembly in def_LQ_assemblies) {
            call GenerateModelsList as LQ_models {
                input:
                assembly = lr_assembly,
                long_score_bias = 1
            }
        }
    }

    if (defined(HQ_assemblies)) {
        Array[AssembledSample] def_HQ_assemblies = select_first([HQ_assemblies])

        scatter (lr_assembly in def_HQ_assemblies) {
            call GenerateModelsList as HQ_models {
                input:
                assembly = lr_assembly,
                long_score_bias = 1
            }
        }
    }

    call WriteModelsFile {
        input:
        models = flatten(select_all([sr_models.models, LQ_models.models, HQ_models.models]))
    }

    call MikadoPrepare {
        input:
        reference_fasta = indexed_reference.fasta,
        models = WriteModelsFile.result,
        scoring_file = scoring_file,
        extra_config = extra_config
    }

    # ORF Calling
    if (orf_caller != "None") {
        if (orf_caller == "Prodigal") {
            call Prodigal {
                input:
                gencode = gencode,
                prepared_transcripts = MikadoPrepare.prepared_fasta
            }
        }

        if (orf_caller == "GTCDS") {
            call GTCDS {
                input:
                prepared_transcripts = MikadoPrepare.prepared_fasta,
                gtf = MikadoPrepare.prepared_gtf
            }
        }

        if (orf_caller == "Transdecoder") {
            call tdc.wf_transdecoder as Transdecoder {
                input:
                prepared_transcripts = MikadoPrepare.prepared_fasta,
                orf_proteins = orf_calling_proteins
            }
        }

        File maybe_orfs = select_first([Prodigal.orfs, GTCDS.orfs, Transdecoder.final_orfs])
    }

    # Mikado Homology
    if (defined(mikado_do_homology_assessment)) {
        call hml.wf_homology as Homology {
            input:
            program = "blastx",
            reference = MikadoPrepare.prepared_fasta,
            protein_db = homology_proteins
        }
    }

    call MikadoSerialise {
        input:
        homology_alignments = Homology.homology,
        clean_seqs_db = Homology.homology_clean_db,
        junctions = junctions,
        orfs = maybe_orfs,
        transcripts = MikadoPrepare.prepared_fasta,
        indexed_reference = indexed_reference,
        config = MikadoPrepare.mikado_config
    }

    call MikadoPick {
        input:
        config_file = MikadoPrepare.mikado_config,
        mikado_db = MikadoSerialise.mikado_db,
        transcripts = MikadoPrepare.prepared_gtf
    }

    output {
        File mikado_config = MikadoPrepare.mikado_config
        File? orfs = maybe_orfs
        Array[File]? homologies = Homology.homology
        Array[File] serialise_out = MikadoSerialise.out
        File pick_metrics = MikadoPick.metrics
        File pick_loci = MikadoPick.loci
        File pick_scores = MikadoPick.scores
        File pick_stats = MikadoPick.stats
    }
}

task WriteModelsFile {
    input {
        Array[String] models
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
        File result = "models.txt"
    }
# awk 'BEGIN{OFS="\t"} {$1=$1} 1' > models.txt transforms inputs looking like:
# "Ara.hisat.stringtie.gtf	Ara.hisat.stringtie	True	0" "Ara.hisat.scallop.gtf	Ara.hisat.scallop	True	0"
# into a proper models file, this is a task because using write_lines(flatten([])) did not work properly in the HPC
    command <<<
        set -euxo pipefail
        for i in "~{sep="\" \"" models}"; do
        echo $i; done | awk 'BEGIN{OFS="\t"} {$1=$1} 1' > models.txt;
    >>>
}

task MikadoPick {
#modes = ("permissive", "stringent", "nosplit", "split", "lenient")
    input {
        File config_file
        File transcripts
        File mikado_db
        String mode = "permissive"
        Int flank = 200
        RuntimeAttr? runtime_attr_override
    }

    Int cpus = 8

    output {
        File metrics = "mikado_pick/mikado-" + mode + ".loci.metrics.tsv"
        File loci = "mikado_pick/mikado-" + mode + ".loci.gff3"
        File scores = "mikado_pick/mikado-" + mode + ".loci.scores.tsv"
        File loci_index = "mikado_pick/mikado-"+mode+".loci.gff3.midx"
        File index_log = "mikado_pick/index_loci.log"
        File stats = "mikado_pick/mikado-" + mode + ".loci.gff3.stats"
    }

    command <<<
        set -euxo pipefail
    export TMPDIR=/tmp
    mkdir -p mikado_pick
    mikado pick ~{"--source Mikado_" + mode} ~{"--mode " + mode} --procs=~{cpus} \
    ~{"--flank " + flank} --start-method=spawn ~{"--json-conf=" + config_file} \
    -od mikado_pick --loci-out mikado-~{mode}.loci.gff3 -lv INFO ~{"-db " + mikado_db} \
    ~{transcripts}
    mikado compare -r mikado_pick/mikado-~{mode}.loci.gff3 -l mikado_pick/index_loci.log --index
    mikado util stats  mikado_pick/mikado-~{mode}.loci.gff3 mikado_pick/mikado-~{mode}.loci.gff3.stats
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

task MikadoSerialise {
    input {
        IndexedReference indexed_reference
        File config
        File transcripts
        Array[File]? homology_alignments
        File? clean_seqs_db
        File? junctions
        File? orfs
        RuntimeAttr? runtime_attr_override
    }
    Int cpus = 8

    output {
        Array[File] out = glob("mikado_serialise/*")
        File mikado_db = "mikado_serialise/mikado.db"
    }

# The following line is a workaround for having no mechanism to output a "prefix" for an optional array expansion, i.e
# See the usages of xml_prefix
    String xml_prefix = if defined(homology_alignments) then "--xml=" else ""

    command <<<
        set -euxo pipefail
    fasta=~{indexed_reference.fasta}
    fai=~{indexed_reference.fai}
    
    ln -s ${fasta} .
    ln -s ${fai} .
    mikado serialise ~{xml_prefix}~{sep="," homology_alignments} ~{"--blast_targets="+clean_seqs_db} ~{"--junctions="+junctions} ~{"--orfs="+orfs} \
    ~{"--transcripts=" + transcripts} --genome_fai=${fai} \
    ~{"--json-conf=" + config} --force --start-method=spawn -od mikado_serialise --procs=~{cpus}
    >>>

    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 8,
        max_retries: 1
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])


    runtime {
        cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
    }
}

task GTCDS {
    input {
        File prepared_transcripts
        File gtf
        RuntimeAttr? runtime_attr_override
    }

    output {
        File orfs = "mikado_prepared.gt_cds.trans.bed12"
        File gff3 = "mikado_prepared.gt_cds.gff3"
    }

    command <<<
        set -euxo pipefail
        awk '$3!~\"(CDS|UTR)\"' ~{gtf} \
        | mikado util convert -if gtf -of gff3 - \
        | gt gff3 -tidy -retainids -addids | gt cds -seqfile ~{prepared_transcripts} - matchdesc \
        | gff3_name_to_id.py - mikado_prepared.gt_cds.gff3 && \
        mikado util convert -t -of bed12 "mikado_prepared.gt_cds.gff3" "mikado_prepared.gt_cds.trans.bed12"
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

task Prodigal {
    input {
        File prepared_transcripts
        String gencode
        RuntimeAttr? runtime_attr_override
    }

    output {
        File orfs = "transcripts.fasta.prodigal.gff3"
    }

    command <<<
        set -euxo pipefail
        code_id=$(python -c "import Bio.Data; print(CodonTable.generic_by_name[~{gencode}].id")
        prodigal -f gff -g "${code_id}" -i "~{prepared_transcripts}" -o "transcripts.fasta.prodigal.gff3"
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

task GenerateModelsList {
    input {
        AssembledSample assembly
        Int long_score_bias = 0
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
        String models = read_string(stdout())
    }

    command <<<
        set -euxo pipefail
        strand="False"
        if [ ~{assembly.strand} != "fr-unstranded" ]; then
            strand="True"
        fi
        echo -e "~{assembly.assembly}\t~{assembly.name}\t${strand}\t~{long_score_bias}"
    >>>
}

task MikadoPrepare {
    input {
        File models
        File reference_fasta
        File? scoring_file
        File? extra_config
        RuntimeAttr? runtime_attr_override
    }

    Int cpus = 8

    output {
        File mikado_config = "mikado.yaml"
        File prepared_fasta = "mikado_prepare/mikado_prepared.fasta"
        File prepared_gtf = "mikado_prepare/mikado_prepared.gtf"
    }

    command <<<
        set -euxo pipefail
        mikado configure \
        ~{"--scoring=" + scoring_file} \
        --list=~{models} \
        ~{"--reference=" + reference_fasta} \
        mikado.yaml

        # Merge special configuration file for this run here
        yaml-merge mikado.yaml ~{extra_config}

        mikado prepare --procs=~{cpus} --json-conf=mikado.yaml -od mikado_prepare --strip_cds
    >>>

    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 8,
        max_retries: 1
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])


    runtime {
        cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
    }
}
