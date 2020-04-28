# REAT - Robust and Extendable eukaryotic Annotation Toolkit

REAT is a robust easy-to-use genome annotation toolkit for turning high-quality genome assemblies into usable and informative resources. REAT makes use of state-of-the-art annotation tools and is robust to varying quality and sources of molecular evidence.

REAT provides an integrated environment that comprises both 
 * a set of workflows geared towards integrating multiple sources of evidence into a genome annotation, and 
 * an execution environment (Docker, Singularity) for these workflows.

## Getting Started

To configure a development environment for REAT you need:

* the REAT source code
* Software dependencies
* A WDL compatible workflow engine (REAT development is mainly geared towards using Cromwell) [**here cromwell is with capital C, elsewhere it is lowercase **]

To obtain the REAT source code, please: [**this is kind of duplicated below**]

```
git clone https://github.com/ei-corebioinformatics/reat
```

While an exhaustive list of software dependencies is available in the appendix (*TODO add a link*), a simpler way of obtaining all the required binaries for REAT is to build a Singularity container based on the definition file (`REAT-Singularity.def`) included in the repository.

```
singularity build REAT.img REAT-Singularity.def
```

Cromwell can be obtained from the original repository at https://github.com/broadinstitute/cromwell/releases.

### Prerequisites

For ease of development, Singularity is recommended. In case this is not available (you are working on MacOS **[note: I forgot the name of the company, but it should be available for MacOS]**), please follow the instructions in the REAT-Singularity.def for building and installing the binary dependencies.

#### Java 8
#### Singularity (optional)
#### Cromwell >= v48

### Installing

First obtain the source code using

```
git clone https://github.com/ei-corebioinformatics/reat
cd reat
```

You should now have the latest development version, in which you will find the `REAT-Singularity.def`. This allows you to build a Singularity container as previously shown in Getting Started(**TODO Add a link to the section, and if possible command**). Alternatively, install the following software dependencies on your system, so that the executables are available  in your `$PATH` environment variable.

* DIAMOND - 0.9.31
* BioPerl
* FullLengtherNext - 1.0.1
* Install BLAST - 2.7.1
* Install MagicBlast - 1.5.0
* LibDeflate - master
* HTSLib - 1.9
* Samtools - 1.9
* BCFTools - 1.9
* BAMtools - 2.5.1
* gclib - 54917d0
* gffread - ba7535f 
* GMAP - 2019-02-15
* MiniMap2 - 2.17
* GenomeTools - 1.5.10
* HISAT2 - 2.1.0
* STAR - 2.7.3a
* seqtk - master
* Stringtie2 - v2.1.1
* Scallop - 0.10.4
* Scallop-lr - 0.9.2
* Prodigal - 2.6.3
* Transdecoder - 5.5.0
* Portcullis - 1.2.2
* Mikado - 2.0

Instructions for building each of the tools can be found in the `REAT-Singularity.def`.  [**redundant?**]

It is recommended to make use of `virtualenv` when installing python packages. Another alternative to manual compilation of all tools listed is using python anaconda within a conda environment.

When preparing to run REAT, make sure the `reat/annotation/scripts` directory is present in the `$PATH` variable on the shell that executes the cromwell run command.

## Running REAT

Cromwell supports a range of execution backends such as cloud services and batch schedulers. These can be configured in files such as those present in the `annotations/cromwell_options`.

### Local

A local backend is the default type of backend, which will be used in case no other backed is present in the configuration file.

Example command for running in a local backend

```
nohup java -Dconfig.file=./cromwell_server_options.conf -jar ~/.cromwell/cromwell.jar run -i ./reat_inputs.json -o workflow_options.json ~/reat/annotation/workflow_entrypoints/main.wdl > reat.stdout 2> reat.stderr &
```

`nohup` will ensure the cromwell instance executing the workflow is not killed if the console running it is terminated.

`java` is a local version of the Java 8 jre command which will run the cromwell-X.jar (in this case its present in the `~/.cromwell/` directory)

`-Dconfig.file=./cromwell_server_options.conf` sets up the configuration for the cromwell instance which will run the workflow, this file contains configurations pertaining to: the backend (i.e. SLURM, local, cloud), the database for maintaining call caching (required for restarting failed cromwell runs), limits on concurrent workflows and number of jobs, and behaviour of the call cache, among others. For a full description of the options available, please refer to the cromwell documentation at (TODO add link)

`run` this is the mode of execution of the Cromwell engine, it supports a server mode and the run mode. The `server` mode acts as a form of headnode for submitting jobs to the backends and serving requests on the running workflows such as queries on progress among other things. The `run` mode provides an immediate option for running the Cromwell instance on a shell with minimal configuration.

`-i reat_inputs.json` Defines the inputs for the WDL workflow definition (here: `main.wdl`). The inputs are defined in a JSON-like format. An example of this file can be found in the SLURM backend section.

`-o workflow_options.json` Contains configuration specific to the execution of a particular workflow run, including  configuration for reading/writing from caches and output options.

### SLURM

To run REAT in a SLURM backend the cromwell instance needs to be configured using the `-Dconfig.file=` parameter as in the example below. This file contains the configuration required by Cromwell to execute jobs using a SLURM backend. It includes details such as how to submit, check and kill a job running on a SLURM backend.

```
#!/bin/bash
#SBATCH -p ei-long
#SBATCH -c 2
#SBATCH --mem=8G
#SBATCH --mail-type=begin,end,fail
#SBATCH -o headnode_cromwell_prodigal.out
#SBATCH -e headnode_cromwell_prodigal.out

source jdk-9.0.4;
export PATH="$PATH:$HOME/scripts/eiannot"
export PATH="$PATH:/ei/workarea/group-ga/Projects/CB-GENANNO-468_REAT-transcriptome_module/Software/reat/annotation/scripts"
export PATH="$PATH:/ei/software/testing/ei_annotation/0.0.3/x86_64/bin"
java -DLOG_MODE=pretty -Dconfig.file=./cromwell_noserver_slurm.conf -jar ./cromwell.jar run -i ./inputs.json -o options.json ../../Software/reat/annotation/workflow_entrypoints/main.wdl
```

An example configuration for running on SLURM backends:

File `cromwell_server_options.conf`:
```
{
    database {
        profile = "slick.jdbc.HsqldbProfile$"
        # This is a file based database stored in the directory where the cromwell instance is started under cromwell-executions/cromwell-db
        db {
            driver = "org.hsqldb.jdbcDriver"
            url = """
            jdbc:hsqldb:file:cromwell-executions/cromwell-db/cromwell-db;
            shutdown=false;
            hsqldb.default_table_type=cached;hsqldb.tx=mvcc;
            hsqldb.result_max_memory_rows=10000;
            hsqldb.large_data=true;
            hsqldb.applog=1;
            hsqldb.lob_compressed=true;
            hsqldb.script_format=3
            """
            connectionTimeout = 120000
            numThreads = 1
            }
    }

    call-caching {
    # Allows re-use of existing results for jobs you've already run
    # (default: false)
    enabled = true

    # Whether to invalidate a cache result forever if we cannot reuse them. Disable this if you expect some cache copies
    # to fail for external reasons which should not invalidate the cache (e.g. auth differences between users):
    # (default: true)
    invalidate-bad-cache-results = true
  }
  backend {
    default = slurm
    providers {
      slurm {
      actor-factory = "cromwell.backend.impl.sfs.config.ConfigBackendLifecycleActorFactory"
        config {
          # Maximum number of jobs to run concurrently (Please check your local SLURM instance configuration for limits)
          concurrent-job-limit = 50

          # This is a list of runtime-attributes to define memory, cpu and queue for different tasks along with their default values
          runtime-attributes = """
          Int runtime_minutes = 1440
          Int cpu = 4
          Int memory_mb = 8000
          String queue = "ei-medium"
          """

          # This configures how to submit a job for this particular backend, some parameters are available from cromwell such as: job_name, cwd, out, err. Others, can be defined and configured in runtime-attributes such as cpu, memory, queue, and runtime.
          submit = """
sbatch -J ${job_name} -D ${cwd} -o ${out} -e ${err} -t ${runtime_minutes} -p ${queue} \
${"-c " + cpu} \
--mem ${memory_mb} \
--wrap "/bin/bash
export PATH="$PATH:/ei/workarea/group-ga/Projects/CB-GENANNO-468_REAT-transcriptome_module/Software/reat/annotation/scripts"
export PATH="/ei/software/testing/ei_annotation/0.0.3/x86_64/bin:$PATH"
${script}"
          """
          # Defines how to kill a job
          kill = "scancel ${job_id}"
          # Defines how to check if a job is running
          check-alive = "squeue -j ${job_id}"
          job-id-regex = "Submitted batch job (\\d+).*"

          # IMPORTANT: Without this configuration value, Cromwell will not check if jobs are still running using the check-alive command.
          exit-code-timeout-seconds = 30
        }
      }
    }
  }
}
```

File `workflow_options.json`
```
{
    "write_to_cache": true,
    "read_from_cache": true
}
```

### Inputs

Example input file `inputs.json`

```
{
    "ei_annotation.paired_samples": [
      {
        "name": "Sex_morph_M", // amazing combination of "Sex" and "fr-unstranded", which reads like "frustrated" >:D
        "strand": "fr-unstranded", 
        "read_pair": [
          {
            "R1": "inputs/sex_morph_M.sort_scaffold_6.R1.fastq",
            "R2": "inputs/sex_morph_M.sort_scaffold_6.R2.fastq"
          }]
      },
      {
        "name": "organ_WLMPM",
        "strand": "fr-unstranded",
        "read_pair": [
          {
            "R1": "inputs/organ_WLMPM.sort_scaffold_6.R1.fastq",
            "R2": "inputs/organ_WLMPM.sort_scaffold_6.R2.fastq"
          }]
      },
      {
        "name": "organ_WMPM",
        "strand": "fr-unstranded",
        "read_pair": [
          {
            "R1": "inputs/organ_WMPM.sort_scaffold_6.R1.fastq",
            "R2": "inputs/organ_WMPM.sort_scaffold_6.R2.fastq"
          }]
      },
      {
        "name": "LIB1777",
        "strand": "fr-firststrand",
        "read_pair": [
          {
            "R1": "inputs/LIB1777.sort_scaffold_6.R1.fastq",
            "R2": "inputs/LIB1777.sort_scaffold_6.R2.fastq"
          }]
      },
      {
        "name": "host_swap_Ara",
        "strand": "fr-firststrand",
        "read_pair": [
          {
            "R1": "inputs/host_swap_Ara.sort_scaffold_6.R1.fastq",
            "R2": "inputs/host_swap_Ara.sort_scaffold_6.R2.fastq"
          }]
      },
      {
        "name": "host_swap_Bean",
        "strand": "fr-firststrand",
        "read_pair": [
          {
            "R1": "inputs/host_swap_Bean.sort_scaffold_6.R1.fastq",
            "R2": "inputs/host_swap_Bean.sort_scaffold_6.R2.fastq"
          }]
      },
      {
        "name": "host_swap_Pea",
        "strand": "fr-firststrand",
        "read_pair": [
          {
            "R1": "inputs/host_swap_Pea.sort_scaffold_6.R1.fastq",
            "R2": "inputs/host_swap_Pea.sort_scaffold_6.R2.fastq"
          }]
      }
    ],
    "ei_annotation.HQ_long_read_samples": [
      {
          "name": "DS_polished",
          "strand": "fr-firststrand",
          "LR": ["inputs/DS_polished.fastq"]
      }
    ],
    "ei_annotation.wf_align.HQ_assembler": "filter",
    "ei_annotation.reference_genome": "../../Reference/DS_Myzus_persicae_scaffold_6.fa",
    "ei_annotation.mikado_scoring_file": "inputs/plant.yaml",
    "ei_annotation.homology_proteins": "inputs/cross_species_proteins.pep.all.fa",
    "ei_annotation.orf_calling_proteins": "inputs/cross_species_proteins.pep.all.fa",
    "ei_annotation.wf_main_mikado.orf_calling_program": "Prodigal",
    "ei_annotation.wf_align.long_read_alignment_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    },
    "ei_annotation.wf_align.long_read_assembly_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    },
    "ei_annotation.wf_align.long_read_indexing_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    },
    "ei_annotation.wf_align.short_read_alignment_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    },
    "ei_annotation.wf_align.short_read_alignment_sort_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    },
    "ei_annotation.wf_align.short_read_assembly_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    },
    "ei_annotation.wf_align.short_read_stats_resources":
    {
        "cpu_cores": 1,
        "max_retries": 2, 
        "mem_gb": 8
    },
    "ei_annotation.wf_main_mikado.homology_alignment_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    },
    "ei_annotation.wf_main_mikado.homology_index_resources":
    {
        "cpu_cores": 1,
        "max_retries": 2, 
        "mem_gb": 8
    },
    "ei_annotation.wf_main_mikado.orf_calling_resources":
    {
        "cpu_cores": 1,
        "max_retries": 2, 
        "mem_gb": 8
    },
    "ei_annotation.wf_main_mikado.protein_alignment_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    },
    "ei_annotation.wf_main_mikado.protein_index_resources":
    {
        "cpu_cores": 8,
        "max_retries": 2, 
        "mem_gb": 16
    }
}
```

