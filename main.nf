#!/usr/bin/env nextflow

import groovy.json.JsonBuilder
nextflow.enable.dsl = 2

include { fastq_ingress } from './lib/fastqingress'
include { nextcladeVersionChecker } from './lib/nextclade'

process checkSampleSheet {
    label "artic"
    cpus 1
    input:
        file "sample_sheet.txt"
    output:
        file "samples.txt"
    """
    check_sample_sheet.py sample_sheet.txt samples.txt
    """
}


process copySchemeDir {
    label "artic"
    cpus 1
    input:
        path scheme_directory
    output:
        path "scheme_dir"
    """
    cp -RL $scheme_directory scheme_dir
    """
}


process preArticQC {
    label "artic"
    cpus 1
    input:
        tuple file(directory), val(sample_id), val(type)
    output:
        file "${sample_id}.stats"
    """
    fastcat -s ${sample_id} -r ${sample_id}.stats -x ${directory} > /dev/null
    """
}


process runArtic {
    label "artic"
    cpus 2
    input:
        tuple file(directory), val(sample_id), val(type)
        file "primer_schemes"
    output:
        path "${sample_id}.consensus.fasta", emit: consensus
        path "${sample_id}.depth.txt", emit: depth_stats
        path "${sample_id}.pass.named.stats", emit: vcf_stats
        tuple(
            val(sample_id),
            path("${sample_id}.pass.named.vcf.gz"),
            path("${sample_id}.pass.named.vcf.gz.tbi"),
            emit: pass_vcf)
        tuple(
            val(sample_id),
            path("${sample_id}.merged.gvcf.named.vcf.gz"),
            path("${sample_id}.merged.gvcf.named.vcf.gz.tbi"),
            emit: merged_gvcf)
        tuple(
            val(sample_id),
            path("${sample_id}.primertrimmed.rg.sorted.bam"),
            path("${sample_id}.primertrimmed.rg.sorted.bam.bai"),
            emit: primertrimmed_bam)
        tuple(
            val(sample_id),
            path("${sample_id}.trimmed.rg.sorted.bam"),
            path("${sample_id}.trimmed.rg.sorted.bam.bai"),
            emit: trimmed_bam)
    """
    run_artic.sh \
        ${sample_id} ${directory} ${params._min_len} ${params._max_len} \
        ${params.medaka_model} ${params.scheme_name} ${params.scheme_dir} \
        ${params.scheme_version} ${task.cpus} ${params._max_softclip_length} ${params.normalise}
    bcftools stats ${sample_id}.pass.named.vcf.gz > ${sample_id}.pass.named.stats
    """
}


process combineDepth {
  label "artic"
  cpus 1
  input:
    path "depth_stats/*"
  output:
    file "all_depth.txt"
  script:
  """
    header_file=`ls depth_stats/* | head -1`
    head -1 \${header_file} > all_depth.txt
    cat depth_stats/* | grep -v depth_fwd >> all_depth.txt
  """
}


process genotypeSummary {
    // Produce a genotype summary spreadsheet
    label "artic"
    cpus 1
    input:
        tuple val(sample_id), file(vcf), file(tbi), file(bam), file(bam_index)
        file "reference.vcf"
    output:
        file "*genotype.csv"
    script:
        def lab_id = params.lab_id ? "--lab_id ${params.lab_id}" : ""
        def testkit = params.testkit ? "--testkit ${params.testkit}" : ""
    """
    genotype_summary.py \
        -b $bam \
        -v $vcf \
        -d reference.vcf \
        --sample $sample_id \
        $lab_id \
        $testkit \
        -o ${csvName}.genotype.csv
    """
}


process combineGenotypeSummaries {
    label "artic"
    cpus 1
    input:
        file "summary_*.csv"
    output:
        file "genotype_summary.csv"
    """
    combine_genotype_summaries.py -g *.csv -o genotype_summary.csv
    """
}


process getVersions {
    label "artic"
    cpus 1
    output:
        path "versions.txt"
    script:
    """
    medaka --version | sed 's/ /,/' >> versions.txt
    minimap2 --version | sed 's/^/minimap2,/' >> versions.txt
    bcftools --version | head -n 1 | sed 's/ /,/' >> versions.txt
    samtools --version | head -n 1 | sed 's/ /,/' >> versions.txt
    artic --version | sed 's/ /,/' >> versions.txt
    """
}


process getParams {
    label "artic"
    cpus 1
    output:
        path "params.json"
    script:
        def paramsJSON = new JsonBuilder(params).toPrettyString()
    """
    # Output nextflow params object to JSON
    echo '$paramsJSON' > params.json
    """
}


process telemetry {
    label "artic"
    cpus 1
    input:
        tuple val(sample_id), file(bams), file(bais), file(vcfs), file(tbis)
        path scheme_bed
        path reference
    output:
        path "telemetry.json", emit: json
    script:
        def samples = sample_id.join(' ')
    """
    output_telemetry.py \
        telemetry.json \
        --scheme_name $params.scheme_name \
        --scheme_bed $scheme_bed \
        --reference $reference \
        --samples $samples \
        --alignments $bams \
        --calls $vcfs
    """
}


process report {
    label "artic"
    cpus 1
    input:
        path "depth_stats/*"
        path "read_stats/*"
        path "nextclade.json"
        path nextclade_errors
        path "pangolin.csv"
        path "genotypes/*"
        path "vcf_stats/*"
        path "consensus_status.txt"
        path "versions/*"
        path "params.json"
        path "consensus_fasta"
        path "telemetry.json"
        val samples
        val types
    output:
        path "wf-artic-*.html"
        path "*.json"
    script:
    // when genotype_variants is false the channel contains a mock file
    def report_name = "wf-artic-" + params.report_name + '.html'
    def genotype = params.genotype_variants ? "--genotypes genotypes/*" : ""
    def nextclade = params.report_clade as Boolean ? "--nextclade nextclade.json" : ""
    def pangolin = params.report_lineage as Boolean ? "--pangolin pangolin.csv" : ""
    def coverage = params.report_coverage as Boolean ? "" : "--hide_coverage"
    def var_summary = params.report_variant_summary as Boolean ? "" : "--hide_variants"
    def debug = params.report_detailed as Boolean ? "--telemetry telemetry.json" : "--hide_debug"
    """
    echo "$pangolin"
    echo "$nextclade"
    report.py \
        consensus_status.txt $report_name \
        $pangolin $coverage $var_summary \
        $nextclade $debug \
        --nextclade_errors $nextclade_errors \
        --revision $workflow.revision \
        --commit $workflow.commitId \
        --min_len $params._min_len \
        --max_len $params._max_len \
        --report_depth $params.report_depth \
        --depths depth_stats/* \
        --summaries read_stats/* \
        --bcftools_stats vcf_stats/* $genotype \
        --versions versions \
        --params params.json \
        --consensus_fasta $consensus_fasta \
        --samples $samples \
        --types $types
    """
}


process report_no_data {
    label "artic"
    cpus 1
    input:
        path "versions/*"
        val error
        path "params.json"
    output:
        path "wf-artic-*.html"
        path "*.json", optional: true
    script:
    // when genotype_variants is false the channel contains a mock file
    def report_name = "wf-artic-" + params.report_name + '.html'
    def error_message = error
    """
    report_error.py \
        --output $report_name \
        --revision $workflow.revision --params params.json --commit $workflow.commitId \
        --versions versions --error_message \"$error_message\"
    """
}


process allConsensus {
    label "artic"
    cpus 1
    input:
        file "*"
    output:
        file "all_consensus.fasta"
        file "consensus_status.txt"
    """
    ls *.consensus.fasta | xargs cat > all_consensus.fasta
    grep "^>" all_consensus.fasta \
        | awk 'BEGIN{OFS="\\t"; print "sample\\tpass"}{print substr(\$1, 2), \$2!="Artic-Fail"}' \
        >> consensus_status.txt
    """
}


process allVariants {
    label "artic"
    cpus 1
    input:
        tuple val(sample_id), file(vcfs), file(tbis)
        file reference
    output:
        tuple file("all_variants.vcf.gz"), file("all_variants.vcf.gz.tbi")
    """
    for vcf in \$(ls *.vcf.gz)
    do
        bcftools norm -c s -O z --fasta-ref $reference \$vcf > norm.\$vcf
        bcftools index -t norm.\$vcf
    done
    if [[ \$(ls norm.*.vcf.gz | wc -l) == "1" ]]; then
        mv norm.*.vcf.gz all_variants.vcf.gz
        mv norm.*.vcf.gz.tbi all_variants.vcf.gz.tbi
    else
        bcftools merge -o all_variants.vcf.gz -O z norm.*.vcf.gz
        bcftools index -t all_variants.vcf.gz
    fi
    """
}

process prep_nextclade {
  label 'artic'
  cpus 1
  input:
      file "reference.fasta"
      file scheme_bed
  output:
      file "primers.csv"
  """
  scheme_to_nextclade.py $scheme_bed reference.fasta primers.csv
  """
}

process nextclade {
    label "nextclade"
    cpus 1
    input:
        file "consensus.fasta"
        file "reference.fasta"
        file scheme_bed
        file "primers.csv"
        path nextclade_dataset
        val nextclade_data_tag
    output:
        file "nextclade.json"
        file "*.errors.csv"
        path "nextclade.version", emit: version

    script:

      update_tag = ''
      // if update_data is true then we will update nextflow on the fly and
      // use that data instead - regardless of profile - this is the SAFEST
      if (params.update_data == true) {
        nextclade_dataset = 'data/sars-cov-2'
        // if the user specifies a tag and update data then that tag will be pulled
        // if not then the latest will be pulled
        if (params.nextclade_data_tag != null) {
          update_tag = '--tag ' + params.nextclade_data_tag
        } else {
          update_tag = '--tag latest'
        }
      }

    """
    if [ "$params.update_data" == "true" ]
    then
      nextclade dataset get --name 'sars-cov-2' --output-dir 'data/sars-cov-2' $update_tag
    fi

    nextclade --version | sed 's/^/nextclade,/' > nextclade.version
    echo "nextclade_data_tag,`cat $nextclade_dataset/tag.json  | grep -Po '"tag": *\\K"[^"]*"' | sed 's/\\"//g'`" >> nextclade.version

    nextclade run \
        --input-fasta consensus.fasta \
        --input-pcr-primers primers.csv \
        --input-dataset $nextclade_dataset \
        --output-json nextclade.json \
        --jobs 1
    """
}


process pangolin {
    label "pangolin"
    cpus 1
    input:
        path "consensus.fasta"
    output:
        path "lineage_report.csv", emit: report
        path "pangolin.version", emit: version
    """
    if [ "$params.update_data" == "true" ]
    then
      pangolin --update
    fi

    pangolin --all-versions 2>&1 | sed 's/: /,/' > pangolin.version
    pangolin $params._pangolin_options consensus.fasta
    """
}


// See https://github.com/nextflow-io/nextflow/issues/1636
// This is the only way to publish files from a workflow whilst
// decoupling the publish from the process steps.
process output {
    // publish inputs to output directory
    label "artic"

    publishDir "${params.out_dir}", mode: 'copy', pattern: "*"
    input:
        file fname
    output:
        file fname
    """
    echo "Writing output files"
    """
}


// workflow module
workflow pipeline {
    take:
        samples
        // scheme_directory
        scheme_dir
        scheme_name
        scheme_version
        reference
        primers
        ref_variants
        nextclade_dataset
        nextclade_data_tag
    main:
        software_versions = getVersions()
        workflow_params = getParams()
        combined_genotype_summary = Channel.empty()
        scheme_directory = copySchemeDir(projectDir.resolve("./data/${scheme_dir}"))
        if ((samples.getClass() == String) && (samples.startsWith("Error"))){
            samples = channel.of(samples)
            html_doc = report_no_data(
                software_versions.collect(),
                samples,
                workflow_params)
            results = html_doc[0].concat(html_doc[1])
        } else {
            read_summaries = preArticQC(samples)
            artic = runArtic(samples, scheme_directory)
            all_depth = combineDepth(artic.depth_stats.collect())
            // collate consensus and variants
            artic.consensus.view()
            all_consensus = allConsensus(artic.consensus.collect())
            all_variants = allVariants(
                artic.pass_vcf.toList().transpose().toList(), reference)
            // genotype summary
            if (params.genotype_variants) {
                genotype_summary = genotypeSummary(
                    artic.merged_gvcf.join(artic.primertrimmed_bam), ref_variants)
                combined_genotype_summary = combineGenotypeSummaries(
                    genotype_summary.collect())
            } else {
                genotype_summary = Channel.fromPath("$projectDir/data/OPTIONAL_FILE")
            }
            // nextclade
            clades = nextclade(
                all_consensus[0], reference, primers, prep_nextclade(reference,primers), nextclade_dataset, nextclade_data_tag)
            // pangolin
            pangolin(all_consensus[0])
            software_versions = software_versions.mix(pangolin.out.version,nextclade.out.version)
            // telemetry
            telemetry_output = telemetry(
                artic.trimmed_bam.join(artic.pass_vcf).toList().transpose().toList(),
                primers,
                reference)
            // report

            html_doc = report(
                artic.depth_stats.collect(),
                read_summaries.collect(),
                clades[0].collect(),
                clades[1].collect(),
                pangolin.out.report.collect(),
                genotype_summary.collect(),
                artic.vcf_stats.collect(),
                all_consensus[1],
                software_versions.collect(),
                workflow_params,
                all_consensus[0],
                telemetry_output,
                // sample_ids
                samples.map{ it -> it[1]}.toList().map{ it.join(' ')},
                // sample types
                samples.map{ it -> it[2]}.toList().map{ it.join(' ')}
                )
            results = all_consensus[0].concat(
                telemetry.out.json,
                all_consensus[1],
                all_variants[0].flatten(),
                clades[0],
                artic.primertrimmed_bam.flatMap { it -> [ it[1], it[2] ] },
                artic.pass_vcf.flatMap { it -> [ it[1], it[2] ] },
                html_doc[0],
                html_doc[1],
                combined_genotype_summary,
                pangolin.out.report,
                all_depth)
            }
    emit:
        results
}


// entrypoint workflow
WorkflowMain.initialise(workflow, params, log)

// here we should check if the scheme exists, if not, list schemes and exit




workflow {

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";

    if (!params.custom_scheme){

      schemes = file(projectDir.resolve("./data/primer_schemes/**bed"), type: 'file', maxdepth: 10)

      valid_scheme_versions = []

      log.info """
      ------------------------------------
      Available Primer Schemes:
      ------------------------------------
      """
      log.info """  Name\t\tVersion"""
      for (scheme in schemes){
        main = scheme.toString().split("primer_schemes/")[1]
        name = main.split("/")[0]
        version = """${main.split("/")[1]}/${main.split("/")[2]}"""
        valid_scheme_versions.add(version)
        log.info """${c_green}  ${name}\t${version}\t${c_reset}"""
      }

      log.info """
      ------------------------------------
      """

      if (params.list_schemes) {
        exit 1
      }



      if (!valid_scheme_versions.any { it == params.scheme_version}) {
          println("`--scheme_version` should be one of: $valid_scheme_versions, for `--scheme_name`: $params.scheme_name")
          exit 1
      }

      if (params.scheme_name == "spike-seq" && !params.genotype_variants) {
          println("`--genotype_variants` is required for scheme: 'spike-seq'")
          exit 1
      }

      if (params.sample && params.detect_samples) {
          println("Select either `--sample` or `--detect_samples`, not both")
          exit 1
      }

      if (!params.min_len) {
          params.remove('min_len')
          if (params.scheme_version.startsWith("Midnight") || params.scheme_version == 'NEB-VarSkip/v1a-long') {
              params._min_len = 150
          } else {
              params._min_len = 400
          }
      } else {
          params._min_len = params.min_len
          params.remove('min_len')
      }
      if (!params.max_len) {
          params.remove('max_len')
          if (params.scheme_version.startsWith("Midnight")) {
              params._max_len = 1200
          } else if (params.scheme_version == 'NEB-VarSkip/v1a-long') {
              params._max_len = 1800
          } else {
              params._max_len = 700
          }
      } else {
          params._max_len = params.max_len
          params.remove('max_len')
      }

      primers_path = """./data/${params.scheme_dir}/${params.scheme_name}/${params.scheme_version}/${params.scheme_name}.scheme.bed"""
      primers = file(projectDir.resolve(primers_path), type:'file', checkIfExists:true)

      reference_path = """./data/${params.scheme_dir}/${params.scheme_name}/${params.scheme_version}/${params.scheme_name}.reference.fasta"""
      reference = file(projectDir.resolve(reference_path),type:'file', checkIfExists:true)

    } else {
      //custom scheme path defined
      log.info """${c_purple}Custom primer scheme selected: ${params.custom_scheme} (WARNING: We do not validate your scheme - use at your own risk!)${c_reset}"""
      //check path for required files
      primers = file("""${params.custom_scheme}/${params.scheme_name}.scheme.bed""", type:'file', checkIfExists:true)
      reference = file("""${params.custom_scheme}/${params.scheme_name}.reference.fasta""", type:'file', checkIfExists:true)


      // check to make sure min and max length have been set

      if (!params.max_len || !params.min_len) {
          log.info """${c_purple}EXITING: --min_len and --max_len parameters must be specified when using custom schemes.${c_reset}"""
          exit 1
      }

      params._max_len = params.max_len
      params.remove('max_len')


      params._min_len = params.min_len
      params.remove('min_len')


    }

    if (!params.max_softclip_length) {
        params.remove('max_softclip_length')
        params._max_softclip_length = 0
    }
    else{
        params._max_softclip_length = params.max_softclip_length
        params.remove('max_softclip_length')
    }

    // Pangolin options
      if (params.pangolin_options == null){
        params.remove('pangolin_options')
        params._pangolin_options = ''
      } else {
        params._pangolin_options = params.pangolin_options
        params.remove('pangolin_options')
      }


    // For nextclade choose the most recent data from the nextclade_data git submodule, or if nexclade_data_tag is set in params use that
    // if the user specifies --nextcalde_data_tag and --update_data - that tag will be pulled a fresh and used

    nextclade_data_tag = params.nextclade_data_tag
    // get the compatible data tag
    (nextclade_data_tag,nextclade_dataset) = nextcladeVersionChecker(nextclade_data_tag)


    // check genotype variants
    if (params.genotype_variants) {
        if (params.genotype_variants == true) {
            ref_variants = file(
                scheme_directory.resolve("${params.scheme_name}.vcf"),
                type:'file', checkIfExists:true)
        } else {
            ref_variants = file(params.genotype_variants, type:'file', checkIfExists:true)
        }
    } else {
        ref_variants = Channel.fromPath("$projectDir/data/OPTIONAL_FILE")
    }

    // check fastq dataset and run workflow
    samples = fastq_ingress([
        "input":params.fastq,
        "sample":params.sample,
        "sample_sheet":params.sample_sheet,
        "sanitize": params.sanitize_fastq,
        "output":params.out_dir])

    results = pipeline(samples, params.scheme_dir, params.scheme_name, params.scheme_version, reference,
        primers, ref_variants, nextclade_dataset, nextclade_data_tag)
    output(results)
}
