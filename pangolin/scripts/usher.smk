#!/usr/bin/env python

import csv
from Bio import SeqIO
import os
import gzip
from pangolin.utils.log_colours import green,cyan,red
from pangolin.utils.hash_functions import get_hash_string
from pangolin.utils.sequence_qc import sequence_qc

import pangolin.pangolearn.pangolearn as pangolearn


##### Report options #####
UNASSIGNED_LINEAGE_REPORTED="None"

##### Target rules #####

if not config.get("usher_protobuf"):
    config["usher_protobuf"]=""

ruleorder: usher_to_report > generate_report

rule all:
    input:
        config["outfile"],
        os.path.join(config["tempdir"],"VOC_report.scorpio.csv")

rule align_to_reference:
    input:
        fasta = config["query_fasta"],
        reference = config["reference_fasta"]
    params:
        trim_start = 265,
        trim_end = 29674,
        sam = os.path.join(config["tempdir"],"mapped.sam")
    output:
        fasta = os.path.join(config["aligndir"],"sequences.aln.fasta")
    log:
        os.path.join(config["tempdir"], "logs/minimap2_sam.log")
    shell:
        """
        minimap2 -a -x asm20 --sam-hit-only --secondary=no -t  {workflow.cores} {input.reference:q} '{input.fasta}' -o {params.sam:q} &> {log:q} 
        gofasta sam toMultiAlign \
            -s {params.sam:q} \
            -t {workflow.cores} \
            --reference {input.reference:q} \
            --trimstart {params.trim_start} \
            --trimend {params.trim_end} \
            --trim \
            --pad > '{output.fasta}'
        """

rule hash_sequence_assign:
    input:
        fasta = rules.align_to_reference.output.fasta
    output:
        designated = os.path.join(config["tempdir"],"hash_assigned.csv"),
        for_inference = os.path.join(config["tempdir"],"not_assigned.fasta")
    params:
        skip_designation_hash = config["skip_designation_hash"]
    run:
        set_hash = {}
        with open(config["designated_hash"],"r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                set_hash[row["seq_hash"]] = row["lineage"]
        
        with open(output.designated,"w") as fw:
            fw.write("taxon,lineage\n")
            with open(output.for_inference, "w") as fseq:
                for record in SeqIO.parse(input.fasta, "fasta"):
                    if record.id!="reference":
                        hash_string = get_hash_string(record)
                        if not params.skip_designation_hash and hash_string in set_hash:
                            fw.write(f"{record.id},{set_hash[hash_string]}\n")
                        else:
                            fseq.write(f">{record.description}\n{record.seq}\n")

rule scorpio:
    input:
        fasta = rules.align_to_reference.output.fasta,
    params:
        constellation_files = " ".join(config["constellation_files"])
    output:
        report = os.path.join(config["tempdir"],"VOC_report.scorpio.csv")
    threads:
        workflow.cores
    log:
        os.path.join(config["tempdir"], "logs/scorpio.log")
    shell:
        """
        scorpio classify \
        -i {input.fasta:q} \
        -o {output.report:q} \
        -t {workflow.cores} \
        --output-counts \
        --constellations {params.constellation_files} \
        --pangolin \
        --list-incompatible \
        --long &> {log:q}
        """

rule get_constellations:
    params:
        constellation_files = " ".join(config["constellation_files"])
    output:
        list = os.path.join(config["tempdir"], "get_constellations.txt")
    shell:
        """
        scorpio list \
        --constellations {params.constellation_files} \
        --pangolin > {output.list:q}
        """


rule sequence_qc:
    input:
    output:
    run:


rule use_usher:
    input:
        fasta = rules.cache_sequence_assign.output.for_inference,
        reference = config["reference_fasta"],
        usher_protobuf = config["usher_protobuf"]
    params:
        vcf = os.path.join(config["tempdir"], "sequences.aln.vcf")
    threads: workflow.cores
    output:
        txt = os.path.join(config["tempdir"], "clades.txt")
    log:
        os.path.join(config["tempdir"], "logs/usher.log")
    shell:
        """
        echo "Using UShER as inference engine."
        if [ -s {input.fasta:q} ]; then
            faToVcf <(cat {input.reference:q} <(echo "") {input.fasta:q}) {params.vcf:q}
            usher -n -D -i {input.usher_protobuf:q} -v {params.vcf:q} -T {workflow.cores} -d '{config[tempdir]}' &> {log}
        else
            rm -f {output.txt:q}
            touch {output.txt:q}
        fi
        """

rule usher_to_report:
    input:
        txt = rules.use_usher.output.txt,
        scorpio_voc_report = rules.scorpio.output.report,
        constellations_list = rules.get_constellations.output.list,
        designated = rules.hash_sequence_assign.output.designated,
        cached = rules.cache_sequence_assign.output.cached,
        qcfail= config["qc_fail"],
        qc_pass_fasta = config["query_fasta"],
        alias_file = config["alias_file"]
    output:
        csv = config["outfile"]
    run:
        voc_dict = {}
        passed = []

        voc_list = []
        with open(input.constellations_list,"r") as f:
            for line in f:
                voc_list.append(line.rstrip())

        with open(input.scorpio_voc_report,"r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                if row["constellations"] != "":
                    voc_dict[row["query"]] = row


        alias_dict = {}
        with open(input.alias_file, "r") as read_file:
            alias_dict = json.load(read_file)
        if "A" in alias_dict:
            del alias_dict["A"]
        if "B" in alias_dict:
            del alias_dict["B"]

        ## Catching scorpio and usher output 
        with open(output.csv, "w") as fw:
            fw.write("taxon,lineage,conflict,ambiguity_score,scorpio_call,scorpio_support,scorpio_conflict,version,pangolin_version,pangoLEARN_version,pango_version,status,note\n")
            
            version = f"PANGO-{config['pango_version']}"
            with open(input.designated,"r") as f:
                reader = csv.DictReader(f)
                note = "Assigned from designation hash."
                for row in reader:
                    
                    fw.write(f"{row['taxon']},{row['lineage']},,,,,,{version},{config['pangolin_version']},{config['pangoLEARN_version']},{config['pango_version']},passed_qc,{note}\n")
                    passed.append(row['taxon'])


            with open(input.cached,"r") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    fw.write(f"{row['taxon']},{row['lineage']},{row['conflict']},{row['ambiguity_score']},{row['scorpio_call']},{row['scorpio_support']},{row['scorpio_conflict']},{row['version']},{row['pangolin_version']},{row['pangoLEARN_version']},{row['pango_version']},{row['status']},{row['note']}\n")
                    passed.append(row['taxon'])

            version = f"PUSHER-{config['pango_version']}"
            with open(input.txt, "r") as f:
                for l in f:
                    name,lineage_histogram = l.rstrip("\n").split("\t")
                    if "*|" in lineage_histogram:
                        # example: A.28*|A.28(1/10),B.1(6/10),B.1.511(1/10),B.1.518(2/10)
                        lineage,histogram = lineage_histogram.split("*|")
                        histo_list = [ i for i in histogram.split(",") if i ]
                        conflict = 0.0
                        if len(histo_list) > 1:
                            max_count = 0
                            max_lineage = ""
                            selected_count = 0
                            total = 0
                            for lin_counts in histo_list:
                                m = re.match('([A-Z0-9.]+)\(([0-9]+)/([0-9]+)\)', lin_counts)
                                if m:
                                    lin, place_count, total = [m.group(1), int(m.group(2)), int(m.group(3))]
                                    if place_count > max_count:
                                        max_count = place_count
                                        max_lineage = lin
                                    if lin == lineage:
                                        selected_count = place_count
                            if selected_count < max_count:
                                # The selected placement was not in the lineage with the plurality
                                # of placements; go with the plurality.
                                lineage = max_lineage
                                conflict = (total - max_count) / total
                            elif total > 0:
                                conflict = (total - selected_count) / total
                        histogram_note = "Usher placements: " + " ".join(histo_list)
                    else:
                        lineage = lineage_histogram
                        conflict = ""
                        histogram_note = ""
                    scorpio_call_info,scorpio_call,scorpio_support,scorpio_conflict,note='','','','',''
                    if name in voc_dict:
                        scorpio_call_info = voc_dict[name]
                        scorpio_call = scorpio_call_info["constellations"]
                        scorpio_support = scorpio_call_info["support"]
                        scorpio_conflict = scorpio_call_info["conflict"]
                        note = f'scorpio call: Alt alleles {scorpio_call_info["alt_count"]}; Ref alleles {scorpio_call_info["ref_count"]}; Amb alleles {scorpio_call_info["ambig_count"]}'

                        scorpio_lineage = scorpio_call_info["mrca_lineage"]
                        expanded_scorpio_lineage = expand_alias(scorpio_lineage, alias_dict)
                        expanded_pango_lineage = expand_alias(lineage, alias_dict)
                        if expanded_scorpio_lineage and expanded_pango_lineage and not expanded_pango_lineage.startswith(expanded_scorpio_lineage):
                            note += f'; scorpio replaced lineage assignment {lineage}'
                            lineage = scorpio_lineage
                        elif "incompatible_lineages" in scorpio_call_info and lineage in scorpio_call_info["incompatible_lineages"].split("|"):
                            note += f'; scorpio replaced lineage assignment {lineage}'
                            lineage = scorpio_lineage

                        if histogram_note:
                            note += f'; {histogram_note}'
                    else:
                        expanded_pango_lineage = expand_alias(lineage, alias_dict)
                        lineage_unassigned = False
                        while expanded_pango_lineage and len(expanded_pango_lineage) > 3:
                            for voc in voc_list:
                                if expanded_pango_lineage.startswith(voc + ".") or expanded_pango_lineage == voc :
                                    # have no scorpio call but an usher voc/vui call
                                    note += f'usher lineage assignment {lineage} was not supported by scorpio'
                                    note += f'; {histogram_note}'
                                    lineage = UNASSIGNED_LINEAGE_REPORTED
                                    conflict = ""
                                    lineage_unassigned = True
                                    break
                            if lineage == UNASSIGNED_LINEAGE_REPORTED:
                                break
                            expanded_pango_lineage = ".".join(expanded_pango_lineage.split(".")[:-1])

                        if not lineage_unassigned:
                            note = histogram_note
                    fw.write(f"{name},{lineage},{conflict},,{scorpio_call},{scorpio_support},{scorpio_conflict},{version},{config['pangolin_version']},,{config['pango_version']},passed_qc,{note}\n")
                    passed.append(name)

            version = f"PANGO-{config['pango_version']}"
            ## Catching sequences that failed qc in the report
            for record in SeqIO.parse(input.qcfail,"fasta"):
                desc_list = record.description.split(" ")
                note = ""
                for i in desc_list:
                    if i.startswith("fail="):
                        note = i.lstrip("fail=")

                fw.write(f"{record.id},None,,,,,,{version},{config['pangolin_version']},{config['pangoLEARN_version']},{config['pango_version']},fail,{note}\n")
            
            for record in SeqIO.parse(input.qc_pass_fasta,"fasta"):
                if record.id not in passed:
                    fw.write(f"{record.id},None,,,,,,{version},{config['pangolin_version']},{config['pangoLEARN_version']},{config['pango_version']},fail,failed_to_map\n")

        print(green(f"Output file written to: ") + f"{output.csv}")
        if config["alignment_out"]:
            print(green(f"Output alignment written to: ") + config["outdir"] +"/sequences.aln.fasta")