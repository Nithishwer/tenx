## Title ----
##
## Post-process the aggregated matrix generated with the 'cellranger aggr' command
##
## Description ----
##
## The script can remove entries for cell barcodes shared between multiple
## samples that were sequenced on the same lane
## (i.e. to address index-hopping on the Illumina HiSeq4000)
##
## Details ----
##
## Cells may also be excluded by providing a blacklist of barcodes.
## This should be a file of a single column.
##
## The script expects a tab delimited sample table with the following coloumns:
## (1) sample_id:  should be identical to the library id  given to 'cellranger aggr'
## (2) seq_id:      the sequencing batch (i.e. by lane)
## (3) agg_id:      an integer that must match the cellranger_aggr aggregation id.
##
## e.g.
##
## $ cat samples.tsv
## sample_id          seq_id     agg_id
## d1_butyrate_mono   1          1
## d1_control_mono    1          2
## d2_butyrate_mono   1          3
## d2_control_mono    1          4
##
## The script will add a "-seq_id-sample_id-agg_id" suffix to the cell barcode
## so that these can be tracked in down-stream analyses, e.g.
##
## $ head agg.clean.dir/barcodes.tsv
## AAACCTGAGGTTCCTA-1-d1_butyrate_mono-1
## AAACCTGGTTCTGTTT-1-d1_butyrate_mono-1
## AAACCTGTCGATCCCT-1-d1_butyrate_mono-1
##
## Usage ----
##
## The script is run by specifying the location of the cellranger aggr matrix and the sample table, e.g.
## $ Rscript cellranger_cleanAggMatrix.R
##           --tenxdir=/gfs/work/ssansom/10x/holm_butyrate/agg/all_samples/outs/filtered_gene_bc_matrices_mex/GRCh38/
##           --sampletable=samples.tsv
##           --outdir=.

message("cellranger_postprocessAggrMatrix.R")
timestamp()

# Libraries ----

stopifnot(
    require(optparse),
    require(methods), # https://github.com/tudo-r/BatchJobs/issues/27
    require(Matrix),
    require(S4Vectors),
    require(tenxutils),
    require(R.utils)
)

# Options ----

option_list <- list(
    make_option(
        c("--tenxdir"),
        dest = "tenxdir",
        help="Path to the directory that contains the input 10x matrix files"
    ),
    make_option(
        c("--sampletable"),
        dest = "sampletable",
        help="Input sample table (sample_id, seq_id, agg_id)"
    ),
    make_option(
        c("--samplenamefields"),
        default="sample",
        dest = "samplenamefields",
        help=paste(
            "Sample name fields supplied as a comma-separated list.",
            "Fields must be separated by underscores in the sample_id metada field."
        )
    ),
    make_option(
        c("--hopping"),
        action="store_true",
        dest = "hopping",
        help="Remove barcodes shared between samples within seq_id"
    ),
    make_option(
        c("--downsample"),
        default="no",
        dest = "downsample",
        help=paste(
            "Downsample UMI counts between samples.",
            "Values: 'no', 'mean', 'median', or appropriate base R function."
        )
    ),
    make_option(
        c("--blacklist"),
        default="none",
        dest = "blacklist",
        help=paste(
            "A file of cell barcodes to exclude (one per line).",
            "Useful if other 10x samples were sequenced on the same lane."
        )
    ),
    make_option(
        c("--usebarcodewhitelist"),
        default=FALSE,
        dest = "usebarcodewhitelist",
        help=paste(
            "Use a barcode whitelist.",
            "If TRUE no other filtering of barcodes is applied"
        )
    ),
    make_option(
        c("--barcodewhitelist"),
        default=NULL,
        dest = "barcodewhitelist",
        help="A (e.g. .tsv) file containing the whitelist of barcodes"
    ),
    make_option(
        c("--outdir"),
        default=".",
        dest = "outdir",
        help="Location for outputs files. Must exist."
    ),
    make_option(
        c("--writeaggmat"),
        action = "store_true",
        dest = "writeaggmat",
        help="write out the cleaned aggregated matrix"),
    make_option(
        c("--writesamplemats"),
        action="store_true",
        dest = "writesamplemats",
        help="write out the cleaned per-sample matrices"
    )
)

opt <- parse_args(OptionParser(option_list=option_list))

cat("Running with options:\n")
print(opt)

# Functions ----

getMetaData <- function(barcodes=barcodes,
                        samples=samples,
                        fields=opt$samplenamefields)
{
  ## Add the sample to barcodes to allow easy regressing out of batch in seurat
  metadata <- data.frame(barcode2table(barcodes))

  metadata$barcode <- rownames(metadata)

  rownames(samples) <- samples$agg_id

  ## Add the seq_id and sample_id
  metadata$seq_id <- as.vector(samples[metadata$agg_id, "seq_id"])
  metadata$sample_id <- as.vector(samples[metadata$agg_id, "sample_id"])

  ## Add individual columns to the metadata for the sample name fields
  sample_name_field_titles <- strsplit(fields, ",")[[1]]

  metadata[,sample_name_field_titles] <- read.table(
    text=metadata$sample_id, sep="_"
  )
  metadata
}

# Input data ----

## Matrix
# TODO: used DropletUtils package instead
matrixFile <- file.path(opt$tenxdir, "matrix.mtx.gz")
stopifnot(file.exists(matrixFile))
cat("Importing matrix from:", matrixFile, " ... ")
matrixUMI <- readMM(gzfile(matrixFile))
cat("Done.\n")
cat(
    "Input matrix size:",
    sprintf("%i rows/genes, %i columns/cells\n", nrow(matrixUMI), ncol(matrixUMI))
)


## Barcodes
barcodeFile <- file.path(opt$tenxdir, "barcodes.tsv.gz")
stopifnot(file.exists(barcodeFile))


cat("Importing cell barcodes from:", barcodeFile, " ... ")
barcodes <- scan(gzfile(barcodeFile), "character")


## Blacklist
if (!identical(opt$blacklist, "none")){
    stopifnot(file.exists(opt$blacklist))
    cat("Importing blacklisted barcodes from:", opt$blacklist, " ... ")
    blacklist <- scan(opt$blacklist, "character")
    cat("... Done.\n")
    blacklistTable <- barcode2table(blacklist)
}


# Preprocess ----

## Set matrix colnames / cell barcodes
colnames(matrixUMI) <- barcodes

## Read in the sample table (produced by the same pipeline task)
## Contains: sample_id, seq_id, agg_id
samples <- DataFrame(read.delim(opt$sampletable, as.is = TRUE))


## Subset to whitelist
if (opt$usebarcodewhitelist) {
    message("Performing barcode whitelisting")
    if(is.null(opt$barcodewhitelist))
    {
        stop("File containing barcode whitelist not specified (--barcodewhitelist)")
    }

    barcode_whitelist <- read.table(opt$barcodewhitelist, as.is=T)$V1

    message("number of barcodes before whitelisting: ", ncol(matrixUMI))
    matrixUMI <- matrixUMI[,colnames(matrixUMI) %in% barcode_whitelist]

    message("number of barcodes after whitelisting: ", ncol(matrixUMI))
}





## Clean barcode hopping, if required ----

if (opt$hopping & !opt$usebarcodewhitelist){
    cat("Removing duplicated cell barcodes within sequencing batches\n")

    goodBarcodes <- c()
    for (seq_batch in unique(samples$seq_id)) {
        cat(sprintf("Processing batch: %i\n", seq_batch))

        # unique() in case cells from a single biological sample
        # were sequenced as 2+ 10x samples
        batch_agg_ids <- unique(
            subset(samples, seq_id == seq_batch, "agg_id", drop=TRUE))

        batchBarcodes <- c()
        for (agg_id in batch_agg_ids){
            batchBarcodes <- c(
                batchBarcodes,
                barcodes[grepl(paste0("-", agg_id, "$"), barcodes)]
                )
        }

        # Split barcodes and agg_id
        barcodeTable <- barcode2table(batchBarcodes)

        codefreq <- table(barcodeTable$code)
        uniqueBarcodes <- names(codefreq[codefreq == 1])

        cat(sprintf("- Total cell barcodes: %i\n", length(batchBarcodes)))
        cat(sprintf("- Unique cell barcodes: %i\n", length(uniqueBarcodes)))

        if (opt$blacklist != "none") {
            uniqueBarcodes <- uniqueBarcodes[!uniqueBarcodes %in% blacklistTable$code]
            cat(sprintf("- Unique cell barcodes after blacklist: %i\n", length(uniqueBarcodes)))
        }

        goodBarcodes <- c(
            goodBarcodes,
            rownames(subset(barcodeTable, code %in% uniqueBarcodes))
            )
    }

    # Subset barcodes and matrix
    matrixUMI <- matrixUMI[, goodBarcodes]
    barcodes <- goodBarcodes

    cat(
        "- New matrix dimensions:",
        sprintf(
            "%i rows (genes), %i columns (cells)\n",
            nrow(matrixUMI), ncol(matrixUMI))
        )
    cat(sprintf("- Remaining barcodes: %i\n", length(barcodes)))
}

# Apply downsampling, if required ----

if (!identical(opt$downsample, "no")) {

    cat("Downsampling: ", opt$downsample, "\n")
    # downsampleCounts drops the colnames
    backup_colnames <- colnames(matrixUMI)

    agg_ids <- barcode2table(colnames(matrixUMI))$agg_id

    matrixUMI <- downsampleMatrix(matrixUMI,
                                downsample_method=opt$downsample,
                                library_ids=agg_ids)

}


## Write out the matrices
featureFile <- file.path(opt$tenxdir,"features.tsv.gz")

## write out the cleaned full matrix ----

if (opt$writeaggmat) {
    aggpath <- file.path(opt$outdir, "agg.processed.dir")
    cat("Writing aggregated matrix to:", aggpath, " ... ")
    metadata <- getMetaData(barcodes, samples, opt$samplenamefields)

    writeMatrix(aggpath, matrixUMI, barcodes,featureFile, metadata)

    cat("Done\n")
}


## Write out per sample matrices ----

if (opt$writesamplemats) {
    cat("Writing out per-sample matrices\n")
    barcodeTable <- barcode2table(barcodes)

    for (for_sample_id in unique(samples$sample_id)) {
        cat(sprintf("Processing sample: %s\n", for_sample_id))
        keep_agg_ids <- subset(samples, sample_id == for_sample_id, "agg_id", drop=TRUE)
        sample_barcodes <- rownames(subset(barcodeTable, agg_id %in% keep_agg_ids))
        sample_matrix <- matrixUMI[, sample_barcodes]
        sample_path <- file.path(opt$outdir, paste0(for_sample_id, ".processed.dir"))

        cat(
        "Written matrix dimensions:",
        sprintf(
            "%i rows (genes), %i columns (cells)\n",
            nrow(sample_matrix), ncol(sample_matrix))
        )
        cat(sprintf("Written barcodes: %i\n", length(sample_barcodes)))

        metadata <- getMetaData(sample_barcodes, samples, opt$samplenamefields)

        writeMatrix(sample_path, sample_matrix, sample_barcodes,
                    featureFile, metadata)

    }
}

timestamp()
message("Completed")
