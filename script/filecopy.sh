#!/usr/bin/env bash
# 
# ================================================================================================================================
# Purpose:           Copy files from one location to another location and performs minor transformations and cleansing if needed
#                    ---------------------------
# Called From:       Tidal agent
# Author:            estark
# ===============================================================================================================================
#
function usage() {
  echo "Copies text files with the following parameters:"
  echo "  --jobname=         REQUIRED. A job name with no spaces and special characters. Example : daily_transactions"
  echo "  --env=             REQUIRED. Environment to run in (dev, e2e, prd, prf)"
  echo "  --files=           REQUIRED. Files to copy"
  echo "  --days=            OPTIONAL. Iterates {date} variable for Last d days." 
  echo "                               If -d not provided {date} = today.  -d 1 = today, -d 2 = yesterday and today"
  echo "  --output_format=   OPTIONAL. Default = gz . File output format. Available options : gz, csv"
  echo "  --output_location= REQUIRED. File output target S3 location. Example : s3://my_s3_bucket/my_target_prefix/"
  echo "  --removefirst=     OPTIONAL. Removes first x lines from the file"
  echo "  --removelast=      OPTIONAL. Removes last x lines from the file"
  echo "  --removeheader     OPTIONAL. Removes header line (no param value is needed)"
  echo "  --addheader        OPTIONAL. Adds the header line to each split files (no param value is needed)"
  echo "  --mergefiles       OPTIONAL. Merges small files into a large file"
  echo "  --splitrows=       OPTIONAL. Max number of rows you want in each file"
  echo 
  echo 
  echo " Examples :" 
  echo "  sh filecopy.sh"
  echo "  --jobname=daily_transactions"
  echo "  --env=prd"
  echo "  --files='/data/folder/subfolder/Fileprefix_{date}*tar.gz'"
  echo "  --days=1"
  echo "  --output_format=csv"
  echo "  --output_location='/data2/anothersubfolder/'"
  echo "  --splitrows=500000"
  echo "  --addheader"
  echo ""
  echo "  sh filecopy.sh"
  echo "  --jobname=daily_transactions"
  echo "  --env=prd"
  echo "  --files='/data/folder/subfolder/Fileprefix_{date}*zip'"
  echo "  --days=10"
  echo "  --output_format=gz"
  echo "  --output_location='s3://mybucket/myprefix/'"
  echo "  --removefirst=1"
  echo "  --removelast=1"
  echo "  --removeheader"
  echo "  --mergefiles"
  exit 1
}

clear
set -e # Exit immediately if a command exits with a non-zero status.

machine=""
pJOBNAME=""
pDAYS=1
pSPLITROWS=0
pOUTPUT_FORMAT="gz"
pMERGE_FILES=""
pREMOVE_FIRST=0
pREMOVE_LAST=0
pREMOVE_HEADER=""
pADD_HEADER=""

optspec=":hv-:"
while getopts "$optspec" optchar; do
    case "${optchar}" in
        -)
            case "${OPTARG}" in
                jobname=*)
                    pJOBNAME="${OPTARG#*=}" ;;
                env=*)
                    pENV="${OPTARG#*=}" ;;
                files=*)
                    pFILES="${OPTARG#*=}" ;;
                days=*)
                    pDAYS=${OPTARG#*=} ;;
                splitrows=*)
                    pSPLITROWS=${OPTARG#*=} ;;
                output_format=*)
                    pOUTPUT_FORMAT="${OPTARG#*=}" ;;
                output_location=*)
                    pTARGET="${OPTARG#*=}" ;;
                removefirst=*)
                    pREMOVE_FIRST=${OPTARG#*=} ;;
                removelast=*)
                    pREMOVE_LAST=${OPTARG#*=} ;;
                removeheader)
                    pREMOVE_HEADER='Yes' ;;
                addheader)
                    pADD_HEADER='Yes' ;;
                mergefiles)
                    pMERGE_FILES='Yes' ;;
                *) 
                    if [ "$OPTERR" != 1 ] || [ "${optspec:0:1}" = ":" ]; then
                        echo "Non-option argument: '-${OPTARG}'" >&2
                    fi ;;
            esac;;
        h) 
            usage ;;
        *)        
            if [ "$OPTERR" != 1 ] || [ "${optspec:0:1}" = ":" ]; then
                echo "Non-option argument: '-${OPTARG}'" >&2
            fi ;;
    esac
done
if [ -z "$pJOBNAME" ]
then
    echo "Need to pass the --jobname argument"
    echo ""
    exit 1
fi
if [ -z "$pENV" ]
then
    echo "Need to pass the --env argument"
    echo ""
    exit 1
fi
if [ -z "$pFILES" ]
then
    echo "Need to pass the --files argument"
    echo ""
    exit 1
fi
if [ -z "$pTARGET" ]
then
    echo "Need to pass the --output_location argument"
    echo ""
    exit 1
fi
if [ $pDAYS -lt 1 ];then
    pDAYS=1
fi

pTARGET=${pTARGET/"{env}"/$pENV}
if [[ $pTARGET == "s3://"* ]]; then
    target_type='s3'
else
    target_type='fs'
fi

echo ------------------------------------------------------------------------------------
echo Files  : $pFILES
echo Target : $pTARGET
echo Output : $pOUTPUT_FORMAT
echo - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

rootdir=./tmp
pTMPDIR=$rootdir/$pJOBNAME
pINPUTDIR=$pTMPDIR/input
pUNZIPDIR=$pTMPDIR/unzipped
pSPLITDIR=$pTMPDIR/split
pOUTPUTDIR=$pTMPDIR/output

mkdir -p $rootdir   
rm -rf $pTMPDIR
mkdir -p $pTMPDIR

function clean_tempdirs() {
    if [ "$(ls -A ${pTMPDIR})" ]; then
        rm -rf $pTMPDIR/*
    fi
    mkdir -p $pINPUTDIR
    mkdir -p $pUNZIPDIR
    mkdir -p $pSPLITDIR
    mkdir -p $pOUTPUTDIR
}

function check_if_file_needs_transformation() {
    f=$1
    file_needs_transformation="No"
    if [[ $pREMOVE_FIRST -gt 0 ]]; then    
        file_needs_transformation="Yes"
    fi
    # Remove last x lines if needed
    if [[ $pREMOVE_LAST -gt 0 ]]; then    
        file_needs_transformation="Yes"
    fi

    # Remove the header if needed
    if [ "$pREMOVE_HEADER" == 'Yes' ]; then    
        file_needs_transformation="Yes"
    fi

    # Split the file if needed
    if [[ $pSPLITROWS -gt 0 ]]; then
        file_needs_transformation="Yes"
    fi

    current_file_format="${f##*.}"
    # Gzip files if asked. This will also move files from unzip to output folder
    if [[  "$current_file_format" != "$pOUTPUT_FORMAT" ]]; then
        file_needs_transformation="Yes"
    fi

    case "$current_file_format" in 
        "zip"|"tar.gz"|"tar")
            file_needs_transformation="Yes"
        ;;
    esac
}
        
function unzip_file() {
    ff=$1
    unzip -o $ff -d $pUNZIPDIR
    rm $ff
    
    echo ">> File unziped :" $ff
}

function untar_file() {
    ff=$1
    tar -zxf $ff -C $pUNZIPDIR/
    rm $ff
    
    echo ">> File untarred :" $ff
}

function remove_first_lines {
    ff=$1
    lines_to_start=$(expr $pREMOVE_FIRST + 1 )
    tail -n +$lines_to_start $ff > $ff.new
    rm $ff
    mv $ff.new $ff

    echo ">> First $pREMOVE_FIRST line(s) removed :" $ff
}

function remove_last_lines {
    ff=$1
    if [ $machine == 'Mac' ]; then
        ghead -n -$pREMOVE_LAST $ff > $ff.new
    else
        head -n -$pREMOVE_LAST $ff > $ff.new
    fi
    rm $ff
    mv $ff.new $ff

    echo ">> Last $pREMOVE_LAST line(s) removed :" $ff
}

function remove_header {
    ff=$1
    lines_to_start=2
    tail -n +$lines_to_start $ff > $ff.new
    rm $ff
    mv $ff.new $ff

    echo ">> Header removed from :" $ff
}

function merge_files {
    mkdir $pTMPDIR/merge
    ffilename=$(basename "$1")
    fname="${ffilename%%.*}"
    cat $pUNZIPDIR/* > $pTMPDIR/merge/$fname.txt
    rm $pUNZIPDIR/*
    mv $pTMPDIR/merge/$fname.txt $pUNZIPDIR/

    echo ">> Files have been merged :" $fname.txt
}

function convert_files_to_zip() {
    zip $pUNZIPDIR/*
    mv $pUNZIPDIR/* $pOUTPUTDIR/
    
    echo ">> File zipped :" $file
}

function convert_files_to_gzip() {
    gzip $pUNZIPDIR/*
    mv $pUNZIPDIR/* $pOUTPUTDIR/
    #rm $file
    #file=$pOUTPUTDIR/$filename.gz
    
    echo ">> File(s) gzipped and moved to $pOUTPUTDIR"
}

function split_file() {
    ff=$1
    echo ">> File to split :" $ff
    filedir="$(dirname "$ff")"/ 
    filename=$(basename $ff)
    filetype="${ff##*.}"

    if [ "$pADD_HEADER" == "Yes" ]; then
        echo ">> Headers will be added"
        # Adds the first line each splitted file
        head -n 1 $ff > $pSPLITDIR/tmp_header.txt
        tail -n +2 $ff | split -l $pSPLITROWS - ${pSPLITDIR}/$filename.
    
        for f in $pSPLITDIR/*.*
        do
            cat "$pSPLITDIR/tmp_header.txt" > "$f.new"
            cat "$f" >> "$f.new"
            mv -f "$f.new" "$f"
        done

        rm -f $pSPLITDIR/tmp_header.txt
        echo ">> Headers added"
    else
        split -l $pSPLITROWS $ff ${pSPLITDIR}/$filename.
    fi
    
    rm $ff
    mv $pSPLITDIR/* $filedir
    echo ">> File split completed"
}

function copy_files_to_s3() {
    aws s3 cp $pOUTPUTDIR $pTARGET --recursive
    echo ">> File(s) copied to : " $pTARGET
}

function copy_files_to_fs() {
    cp $pOUTPUTDIR/* $pTARGET
    echo ">> File(s) copied to : " $pTARGET
}

function copy_files() {
    # iterate files found in $pFILES
    echo "-----------------------------------------------------------------"
    echo ">> File(s) to be processed : " $pFILES
    echo "-----------------------------------------------------------------"

    for inputfile in $pFILES
    do      
        echo ">>> File to Copy :" $inputfile
        clean_tempdirs
        filename=$(basename $inputfile)
        { #try
            cp $inputfile $pINPUTDIR/$filename && {
                inputfile=$pINPUTDIR/$filename
                echo ">>>" $inputfile "has been copied to" $pINPUTDIR/$filename
            }            
        } || { 
            # catch
            echo "!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!"
            echo ">>> Cannot copy" $inputfile "to" $pINPUTDIR/$filename
            echo "Exiting the script"
            echo "!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!"
            exit 1
        }

        file_basedir=$(dirname $inputfile)
        if [[ $file_basedir != $pINPUTDIR ]]; then
            echo "!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!"
            echo ">>> File is not in " $pINPUTDIR
            echo ">>> Exiting the script"
            echo "!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!-!"
            exit 1
        fi

        # Check the script parameters to see if the file needs decompression
        
        check_if_file_needs_transformation $inputfile;
        if [ "$file_needs_transformation" = 'Yes' ]; then

            # Move file(s) to Unzip folder
            if [[ $inputfile == *.zip ]]; then
                unzip_file $inputfile

            # Untar the file if needed
            elif [[ $inputfile == *.tar.gz ]]; then
                untar_file $inputfile

            else
                # Assuming else files are csv/text files
                # Move the file to Unzip dir 
                mv $inputfile $pUNZIPDIR
            fi;

            for file in $pUNZIPDIR/*.*
            do
                echo " >> File : " $file
                
                # if file is not empty
                if [ -s $file ] 
                then 
                    # Remove first x lines if needed
                    if [[ $pREMOVE_FIRST -gt 0 ]]; then    
                        remove_first_lines $file
                    fi
                    # Remove last x lines if needed
                    if [[ $pREMOVE_LAST -gt 0 ]]; then    
                        remove_last_lines $file
                    fi
                    
                    # Remove the header if needed
                    if [ "$pREMOVE_HEADER" == 'Yes' ]; then    
                        remove_header $file
                    fi
                else 
                    echo " >> Removing empty file : " $file
                    rm $file
                fi
            done

            #Check if Unzip folder is not empty
            if [ "$(ls -A $pUNZIPDIR)" ]; then
                # Merge small files if needed
                if [ "$pMERGE_FILES" == "Yes" ]; then    
                    merge_files $filename
                fi

                # Split files if needed
                if [[ $pSPLITROWS -gt 0 ]]; then
                    for file in $pUNZIPDIR/*.*
                    do
                        split_file $file
                    done
                fi

                # Gzip files if asked. This will also move files from unzip to output folder
                if [ "$pOUTPUT_FORMAT" == "gz" ]; then
                    convert_files_to_gzip
                
                # Zip files if asked. This will also move files from unzip to output folder
                elif [ "$pOUTPUT_FORMAT" == "zip" ]; then
                    convert_files_to_zip
                
                else
                    # Move files from unzip to output folder
                    mv $pUNZIPDIR/* $pOUTPUTDIR/
                fi                
            else
                echo ">>>> Unzip folder is Empty"
            fi

        else
            # Move files that didn't need any processing from Inputdir to Outputdir
            mv $pINPUTDIR/* $pOUTPUTDIR/
        fi
        
        # Copy the files from Output folder to the target location
        if [ "$(ls -A $pOUTPUTDIR)" ]; then
            if [ "$target_type" == "s3" ]; then
                copy_files_to_s3
            else
                copy_files_to_fs
            fi
        else
            echo ">>>> Output folder is Empty"
        fi
        
    done
}

function get_os_type() {
    unameOut="$(uname -s)"
    case "${unameOut}" in
        Linux*)     machine=Linux;;
        Darwin*)    machine=Mac;;
        CYGWIN*)    machine=Cygwin;;
        MINGW*)     machine=MinGw;;
        *)          machine="UNKNOWN:${unameOut}"
    esac
}

echo 
echo ">>>>>>  FILE COPY STARTED <<<<<<<<<<"
echo 

# Get the machine OS type
get_os_type

# Iterate dates if specified
if [[ "$pTARGET" == *"{date}"* ]] || [[ "$pFILES" == *"{date}"* ]]; then
    echo ">>> Iterating dates"
    filepath=$pFILES
    target=$pTARGET
    pDAYS=$(($pDAYS - 1))

    today=$(date +%Y-%m-%d)
    if [ $machine == 'Mac' ]; then
        tomorrow=$(date -j -v +1d -f "%Y-%m-%d" $today +%Y-%m-%d)
        d=$(date -j -v -${pDAYS}d -f "%Y-%m-%d" $today +%Y-%m-%d)
    else
        tomorrow=$(date -I -d "$today + 1 day")
        d=$(date -I -d "$today - ${pDAYS} day")
    fi
    
    while [ "$d" != $tomorrow ]; do 
        pFILES=${filepath/"{date}"/${d//-}}
        pTARGET=${target/"{date}"/${d//-}}

        num_of_files=$(ls -d $pFILES | wc -l)
        if [ $num_of_files -gt 0 ]; then
            # Execute Copy
            copy_files
        else
            echo "--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--"
            echo ">> No File(s) found to process : " $pFILES
            echo "--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--!--"
        fi

        if [ $machine == 'Mac' ]; then
            d=$(date -j -v +1d -f "%Y-%m-%d" $d +%Y-%m-%d)
        else
            d=$(date -I -d "$d + 1 day")
        fi
    done
else
    # Otherwise Execute Copy
    copy_files
fi

rm -rf $pTMPDIR

echo 
echo ">>>>>>  FILE COPY FINISHED <<<<<<<<<<"
echo 