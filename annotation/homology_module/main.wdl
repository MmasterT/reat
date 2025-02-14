version 1.0
import "./rt_struct.wdl"

struct GenomeAnnotation {
    File genome
    File annotation_gff
}

struct GenomeProteins {
    File genome
    File annotation_gff
    File protein_sequences
}

workflow ei_homology {
    input {
        Array[GenomeAnnotation]? annotations
        Array[File]? protein_sequence_files
        File genome_to_annotate
        File mikado_scoring
        File mikado_config
        String species
        Int codon_table
        String output_prefix = "xspecies"
        RuntimeAttr? index_attr
        RuntimeAttr? score_attr
        RuntimeAttr? aln_attr
        RuntimeAttr? mikado_attr
    }

    call IndexGenome {
        input:
        genome = genome_to_annotate,
        runtime_attr_override = index_attr
    }

    if (defined(protein_sequence_files)) {
        scatter (protein_sequence_file in select_first([protein_sequence_files])) {
            call AlignProteinSequences {
                input:
                genome_index = IndexGenome.genome_index,
                proteins = protein_sequence_file,
                species = species,
                out_prefix = sub(basename(protein_sequence_file), "\.[^/.]+$", ""),
                runtime_attr_override = aln_attr
            }
        }
    }

    if (defined(annotations)) {
        scatter (annotation in select_first([annotations])) {
            call PrepareAnnotations {
                input:
                annotation = annotation,
                codon_table = codon_table
            }

            GenomeProteins cleaned_up = object { genome: annotation.genome, annotation_gff: PrepareAnnotations.cleaned_up_gff, protein_sequences: PrepareAnnotations.proteins}
            String out_prefix = sub(basename(cleaned_up.annotation_gff), "\.[^/.]+$", "")
            String ref_prefix = sub(basename(cleaned_up.genome), "\.[^/.]+$", "")

            call AlignProteins {
                input:
                    genome_index = IndexGenome.genome_index,
                    genome_to_annotate = genome_to_annotate,
                    genome_proteins = cleaned_up,
                    ref_prefix = ref_prefix,
                    out_prefix = out_prefix,
                    species = species,
                    runtime_attr_override = aln_attr
            }

            call PrepareAlignments {
                input:
                annotation_cdnas = PrepareAnnotations.cdnas,
                annotation_bed = PrepareAnnotations.bed,
                ref_prefix = ref_prefix,
                raw_alignments = AlignProteins.raw_alignments,
                genome_to_annotate = genome_to_annotate
            }

            String aln_prefix = sub(basename(PrepareAlignments.clean_alignments), "\.[^/.]+$", "")

            call ScoreAlignments {
                input:
                cdnas = PrepareAlignments.cdnas,
                bed = PrepareAlignments.bed,
                groups = PrepareAlignments.groups,
                aln_prefix = aln_prefix,
                ref_prefix = ref_prefix,
                runtime_attr_override = score_attr
            }

            call CombineResults {
                input:
                alignment_compare_detail = ScoreAlignments.alignment_compare_detail,
                alignment_gff = PrepareAlignments.clean_alignments
            }
        }
        call ScoreSummary {
            input:
            alignments_compare = ScoreAlignments.alignment_compare_detail
        }
    }

    Array[File] all_alignments = flatten(select_all([CombineResults.augmented_alignments_gff, AlignProteinSequences.raw_alignments]))
    scatter (alignment in all_alignments) {
        call CombineXspecies {
            input:
            alignment = alignment,
            alignments = all_alignments
        }
    }

    # With the results so far and some optional inputs such as assemblies and junctions
    # consolidate them in a mikado run that should incorporate UTRs and add junctions to the scoring

    call Mikado {
        input:
        reference = genome_to_annotate,
        extra_config = mikado_config,
        xspecies = CombineXspecies.xspecies_scored_alignment,
        output_prefix = output_prefix,
        runtime_attr_override = mikado_attr
    }

    call MikadoPick {
        input:
        config_file = Mikado.mikado_config,
        scoring_file = mikado_scoring,
        mikado_db = Mikado.mikado_db,
        transcripts = Mikado.prepared_gtf,
        output_prefix = output_prefix,
        runtime_attr_override = mikado_attr
    }

    call MikadoSummaryStats {
        input:
        stats = [MikadoPick.stats],
        output_prefix = output_prefix
    }

    output {
        Array[File]? xspecies_combined_alignments = CombineXspecies.xspecies_scored_alignment
        Array[File]? clean_annotations = PrepareAnnotations.cleaned_up_gff
        Array[File]? mgc_evaluation = ScoreAlignments.alignment_compare
        Array[File]? mgc_evaluation_detail = ScoreAlignments.alignment_compare_detail
        Array[File]? annotation_filter_stats = PrepareAnnotations.stats
        Array[File]? alignment_filter_stats = PrepareAlignments.stats
        File?        mgc_score_summary = ScoreSummary.summary_table
        File loci = MikadoPick.loci
        File scores = MikadoPick.scores
        File metrics = MikadoPick.metrics
        File stats = MikadoPick.stats
        File stats_summary = MikadoSummaryStats.summary
    }
}

task Mikado {
    input {
        File reference
        File extra_config
        Int min_cdna_length = 100
        Int max_intron_length = 1000000
        Array[File] xspecies
        File? utrs
        File? junctions
        String output_prefix
        RuntimeAttr? runtime_attr_override
    }

    output {
        File mikado_config = output_prefix+"-mikado.yaml"
        File prepared_fasta = output_prefix+"-mikado/mikado_prepared.fasta"
        File prepared_gtf = output_prefix+"-mikado/mikado_prepared.gtf"
        File mikado_db = output_prefix+"-mikado/mikado.db"
    }

    Int cpus = 8
    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 16,
        max_retries: 1,
        queue: ""
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

    Int task_cpus = select_first([runtime_attr.cpu_cores, cpus])

    command <<<
        set -euxo pipefail
        export TMPDIR=/tmp
        # Create the lists file
        for i in ~{sep=" " xspecies}
        do
        bname=$(basename ${i})
        label=${bname%%.*}
        echo -e "${i}\t${label}\tTrue\t1\tTrue" >> list.txt
        done

        apply_pad="--no-pad "
        if [ "" != "~{utrs}" ]
        then
            apply_pad=""
            label="UTRs"
            gffread -vE ~{utrs} > preprocessed_utrs.gff
            echo -e "$(pwd -P)/preprocessed_utrs.gff\t${label}\tTrue\t0\tFalse" >> list.txt
        fi

        # mikado configure
        mikado configure $apply_pad --only-reference-update --check-references --reference-update \
        --max-intron-length ~{max_intron_length} --minimum-cdna-length ~{min_cdna_length} \
        --reference ~{reference} --list=list.txt --copy-scoring plant.yaml original-mikado.yaml

        yaml-merge -s original-mikado.yaml ~{"-m " + extra_config} -o ~{output_prefix}-mikado.yaml

        # mikado prepare
        mikado prepare --procs=~{task_cpus} --json-conf ~{output_prefix}-mikado.yaml -od ~{output_prefix}-mikado

        # mikado serialise
        mikado serialise --force ~{"--junctions " + junctions} --transcripts ~{output_prefix}-mikado/mikado_prepared.fasta \
        --json-conf=~{output_prefix}-mikado.yaml --start-method=spawn -od ~{output_prefix}-mikado --procs=~{task_cpus}

    >>>

    runtime {
        cpu: task_cpus
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
        queue: select_first([runtime_attr.queue, default_attr.queue])
    }

}

task MikadoPick {
    input{
        File config_file
        File? extra_config
        File scoring_file
        File transcripts
        File mikado_db
        String output_prefix
        RuntimeAttr? runtime_attr_override
    }

    Int cpus = 8
    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 16,
        max_retries: 1,
        queue: ""
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

    Int task_cpus = select_first([runtime_attr.cpu_cores, cpus])

    output {
        File index_log  = output_prefix + "-index_loci.log"
        File loci_index = output_prefix + ".loci.gff3.midx"
        File loci       = output_prefix + ".loci.gff3"
        File scores     = output_prefix + ".loci.scores.tsv"
        File metrics    = output_prefix + ".loci.metrics.tsv"
        File stats      = output_prefix + ".loci.gff3.stats"
        File subloci    = output_prefix + ".subloci.gff3"
        File monoloci   = output_prefix + ".monoloci.gff3"
    }

    command <<<
    set -euxo pipefail
    export TMPDIR=/tmp
    yaml-merge -s ~{config_file} ~{"-m " + extra_config} -o pick_config.yaml
    mikado pick --source Mikado_~{output_prefix} --procs=~{task_cpus} --scoring-file ~{scoring_file} \
    --start-method=spawn --json-conf=pick_config.yaml \
    --loci-out ~{output_prefix}.loci.gff3 -lv INFO ~{"-db " + mikado_db} \
    --subloci-out ~{output_prefix}.subloci.gff3 --monoloci-out ~{output_prefix}.monoloci.gff3 \
    ~{transcripts}
    mikado compare -r ~{output_prefix}.loci.gff3 -l ~{output_prefix}-index_loci.log --index
    mikado util stats  ~{output_prefix}.loci.gff3 ~{output_prefix}.loci.gff3.stats
    >>>

    runtime {
        cpu: task_cpus
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
        queue: select_first([runtime_attr.queue, default_attr.queue])
    }

}

task ScoreSummary {
    input {
        Array[File] alignments_compare
    }

    output {
        File summary_table = "ScoreAlignments/all_avgF1.bin.txt"
    }

    command <<<
        set -euxo pipefail
        mkdir ScoreAlignments
        cd ScoreAlignments
        for i in ~{sep=" " alignments_compare}; do
            echo $i;
            cat $i |awk -vOFS=" " 'NR > 1 {print $11,$13}' |awk '{sum = 0; for (i = 1; i <= NF; i++) sum += $i; sum /= NF; print sum}' | \
            awk 'BEGIN { delta = (delta == "" ? 0.1 : delta) }
{bucketNr = int(($0+delta) / delta); cnt[bucketNr]++; numBuckets = (numBuckets > bucketNr ? numBuckets : bucketNr)}
END { for (bucketNr=1; bucketNr<=numBuckets; bucketNr++) {
        end = beg + delta
        printf "%0.1f-%0.1f,%d\n", beg, end, cnt[bucketNr]
        beg = end
    }
}' > `basename $i`_avgF1.tbin.txt;
        done;

        cat <<COL1 > col1
bin
0.0-0.1
0.1-0.2
0.2-0.3
0.3-0.4
0.4-0.5
0.5-0.6
0.6-0.7
0.7-0.8
0.8-0.9
0.9-1.0
1.0-1.1
COL1
        for i in comp*avgF1.tbin.txt; do
            file=$(echo `basename $i` |cut -d . -f1);
            printf ",$file\n" > temp;
            cat $i >> temp;
            cut -d , -f2 temp > ${file}_temp;
        done;
        paste -d , col1 comp*temp > all_avgF1.bin.txt;
        rm *temp*;
        rm col1;
        rm *_avgF1.tbin.txt;
    >>>
}

task CombineXspecies {
    input {
        File alignment
        Array[File] alignments
        RuntimeAttr? runtime_attr_override
    }

    String out_prefix = sub(basename(alignment), "\.[^/.]+$", "")

    output {
        File xspecies_scored_alignment = out_prefix + ".xspecies_scores.gff"
    }

    Int cpus = 1
    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 16,
        max_retries: 1,
        queue: ""
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

    Int task_cpus = select_first([runtime_attr.cpu_cores, cpus])

    command <<<
        set -euxo pipefail
        for o in ~{sep=' ' alignments};
        do
            if [ "~{alignment}" != "${o}" ]
            then
                o_name=$(basename $o)
                mikado compare --processes 1 -r ~{alignment} -p $o -o ~{out_prefix}_vs_${o_name%.*}
            fi
        done

        combine_alignment_with_compare --alignment ~{alignment} --compare ~{out_prefix}_vs_*.refmap > ~{out_prefix}.xspecies_scores.gff
    >>>

    runtime {
        continueOnReturnCode: [0]
        cpu: task_cpus
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
        queue: select_first([runtime_attr.queue, default_attr.queue])
    }
}

task IndexGenome {
    input {
        File genome
        RuntimeAttr? runtime_attr_override
    }

    output {
        Array[File] genome_index = glob("genome_to_annotate.*")
    }

    Int cpus = 6
    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 16,
        max_retries: 1,
        queue: ""
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

    Int task_cpus = select_first([runtime_attr.cpu_cores, cpus])

    command <<<
        set -euxo pipefail
        ln ~{genome} genome_to_annotate.fasta
        spaln -W -KP -t~{task_cpus} genome_to_annotate.fasta
    >>>

    runtime {
        continueOnReturnCode: [0, -1]
        cpu: task_cpus
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
        queue: select_first([runtime_attr.queue, default_attr.queue])
    }
}

task PrepareAnnotations {
    input {
        GenomeAnnotation annotation
        String out_prefix = sub(basename(annotation.annotation_gff),  "\.[^/.]+$", "")
        Int min_cds_len = 20 # nts
        Int max_intron_len = 200000
        Int min_exon_len = 20
        Int codon_table
        Array[String] filters = "all"
    }

    output {
        File cleaned_up_gff = 'Annotations/' + out_prefix + ".clean.extra_attr.gff"
        File stats = 'Annotations/' + out_prefix + ".annotation.stats"
        File proteins = 'Annotations/' + out_prefix + ".proteins.fa"
        File cdnas = 'Annotations/' + out_prefix + ".cdna.fa"
        File bed = 'Annotations/' + out_prefix + ".bed"
    }

    command <<<
        set -euxo pipefail
        mkdir Annotations/
        cd Annotations
        case ~{annotation.annotation_gff} in
            *.gz) gunzip <~{annotation.annotation_gff};;
            *)    cat ~{annotation.annotation_gff};;
        esac | gffread --keep-genes -E -o sorted_annotation.gff > ~{annotation.annotation_gff}.gffread.out 2> ~{annotation.annotation_gff}.gffread.err
        xspecies_cleanup --merge --filters ~{sep=" " filters} \
        --annotation sorted_annotation.gff -g ~{annotation.genome} \
        --max_intron ~{max_intron_len} --min_exon ~{min_exon_len} --min_protein ~{min_cds_len} \
        -x ~{out_prefix}.cdna.fa --bed ~{out_prefix}.bed \
        -o ~{out_prefix}.clean.extra_attr.gff > ~{out_prefix}.annotation.stats
        cat ~{out_prefix}.cdna.fa | seqkit translate -T ~{codon_table} -o ~{out_prefix}.proteins.fa
    >>>
}

task AlignProteins {
    input {
        Array[File] genome_index
        File genome_to_annotate
        GenomeProteins genome_proteins
        String species
        Int min_spaln_exon_len = 20
        Int min_coverage = 80
        Int min_identity = 50
        Int max_per_query = 4
        Int recursion_level = 6
        String ref_prefix
        String out_prefix
        RuntimeAttr? runtime_attr_override
    }
    Int cpus = 8
    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 32,
        max_retries: 1,
        queue: ""
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

    Int task_cpus = select_first([runtime_attr.cpu_cores, cpus])

    output {
        File raw_alignments = ref_prefix+".alignment.gff"
    }

    command <<<
        set -euxo pipefail
        ln ~{sub(genome_index[0], "\.[^/.]+$", "")}.* .
        ln -s ~{genome_proteins.protein_sequences} "./~{basename(genome_proteins.protein_sequences)}"
        spaln -t~{task_cpus} -KP -O0,12 -Q~{recursion_level} -M~{max_per_query}.~{max_per_query} ~{"-T"+species} -dgenome_to_annotate -o ~{out_prefix} -yL~{min_spaln_exon_len} "~{basename(genome_proteins.protein_sequences)+" P"}"
        sortgrcd -O4 ~{out_prefix}.grd | tee ~{out_prefix}.s | spaln2gff --min_coverage ~{min_coverage} --min_identity ~{min_identity} -s "spaln" > ~{ref_prefix}.alignment.gff
    >>>

    runtime {
        cpu: task_cpus
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
        queue: select_first([runtime_attr.queue, default_attr.queue])
    }

}


task AlignProteinSequences {
    input {
        Array[File] genome_index
        File proteins
        String species
        Int min_spaln_exon_len = 20
        Int min_coverage = 80
        Int min_identity = 50
        Int max_per_query = 4
        Int recursion_level = 6
        String out_prefix
        RuntimeAttr? runtime_attr_override
    }

    Int cpus = 8
    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 32,
        max_retries: 1,
        queue: ""
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

    Int task_cpus = select_first([runtime_attr.cpu_cores, cpus])

    output {
        File raw_alignments = basename(proteins)+".alignment.gff"
    }

    command <<<
        set -euxo pipefail
        ln ~{sub(genome_index[0], "\.[^/.]+$", "")}.* .
        ln -s ~{proteins} .
        spaln -t~{task_cpus} -KP -O0,12 -Q~{recursion_level} -M~{max_per_query}.~{max_per_query} ~{"-T"+species} -dgenome_to_annotate -o ~{out_prefix} -yL~{min_spaln_exon_len} ~{basename(proteins)}
        sortgrcd -O4 ~{out_prefix}.grd | tee ~{out_prefix}.s | spaln2gff --min_coverage ~{min_coverage} --min_identity ~{min_identity} -s "spaln" > ~{basename(proteins)}.alignment.gff
    >>>


    runtime {
        cpu: task_cpus
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
        queue: select_first([runtime_attr.queue, default_attr.queue])
    }

}

task PrepareAlignments {
    input {
        String ref_prefix

        Int max_intron_len = 200000
        Int min_filter_exon_len = 20
        Int min_cds_len = 20
        Boolean show_intron_len = false
        Array[String] filters = "none"

        File raw_alignments
        File genome_to_annotate
        File annotation_cdnas
        File annotation_bed
    }

    output {
        File clean_alignments = ref_prefix + ".alignment.stop_extended.extra_attr.gff"
        File stats = ref_prefix + ".alignment.stats"
        File cdnas = "all_cdnas.fa"
        File bed = "all_cdnas.bed"
        File groups = "groups.txt"
    }

    command <<<
        set -euxo pipefail

        xspecies_cleanup ~{if show_intron_len then "--show_intron_len" else ""} \
        --filters ~{sep=" " filters} --max_intron ~{max_intron_len} --min_exon ~{min_filter_exon_len} --min_protein ~{min_cds_len} \
        -g ~{genome_to_annotate} -A ~{raw_alignments} --bed ~{ref_prefix}.alignment.bed \
        -x ~{ref_prefix}.alignment.cdna.fa \
        -o ~{ref_prefix}.alignment.stop_extended.extra_attr.gff > ~{ref_prefix}.alignment.stats

        create_mgc_groups -f ~{ref_prefix}.alignment.cdna.fa

        cat ~{ref_prefix}.alignment.cdna.fa ~{annotation_cdnas}  > all_cdnas.fa
        cat ~{ref_prefix}.alignment.bed ~{annotation_bed} > all_cdnas.bed
    >>>

    runtime {
        cpu: 1
        memory: "8 GB"
        maxRetries: 1
    }

}

task ScoreAlignments {
    input {
        File cdnas
        File bed
        File groups
        String aln_prefix
        String ref_prefix
        RuntimeAttr? runtime_attr_override
    }


    output {
        File alignment_compare = 'ScoreAlignments/' + "comp_"+aln_prefix+"_"+ref_prefix+".tab"
        File alignment_compare_detail = 'ScoreAlignments/' + "comp_"+aln_prefix+"_"+ref_prefix+"_detail.tab"
    }

    Int cpus = 4
    RuntimeAttr default_attr = object {
        cpu_cores: "~{cpus}",
        mem_gb: 32,
        max_retries: 1,
        queue: ""
    }

    RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

    Int task_cpus = select_first([runtime_attr.cpu_cores, cpus])

    command <<<
        set -euxo pipefail
        mkdir ScoreAlignments/
        cd ScoreAlignments
        multi_genome_compare -t ~{task_cpus} --groups ~{groups} \
        --cdnas ~{cdnas} --bed12 ~{bed} \
        -o comp_~{aln_prefix}_~{ref_prefix}.tab -d comp_~{aln_prefix}_~{ref_prefix}_detail.tab
    >>>

    runtime {
        cpu: task_cpus
        memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GB"
        maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
        queue: select_first([runtime_attr.queue, default_attr.queue])
    }

}


task CombineResults {
    input {
        File alignment_compare_detail
        File alignment_gff
        Int? exon_f1_filter
        Int? junction_f1_filter
    }

    String aln_prefix = sub(basename(alignment_gff), "\.[^/.]+$", "")

    output {
        File augmented_alignments_gff = aln_prefix+".mgc.gff"
    }

    command <<<
        set -euxo pipefail
        combine_alignments_with_mgc --detail ~{alignment_compare_detail} ~{'--exon_f1_filter ' + exon_f1_filter} \
        ~{'--junction_f1_filter ' + junction_f1_filter} --gff ~{alignment_gff} -o ~{aln_prefix}.mgc.gff
    >>>
}

task MikadoSummaryStats {
    input {
        Array[File] stats
        String output_prefix
    }

    output {
        File summary = output_prefix + ".summary.stats.tsv"
    }

    command <<<
    mikado_summary_stats ~{sep=" " stats} > ~{output_prefix}.summary.stats.tsv
    >>>
}
