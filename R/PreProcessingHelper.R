###############  Prepare for Coverage ######################

## helper function to prepare coverage and gc data
## given a GRange object and bam file, 
## calculate average coverage for each range
## a helper function for 'getCoverage()' function
calculateSubCoverage = function(
    range,
    bam){
    ## read bam file from given ranges,
    ## filter out duplicated reads, secondary reads and unmapped reads
    ## exclude reads with mapQ==0
    param = ScanBamParam(flag=scanBamFlag(isUnmappedQuery=FALSE, 
                                            isSecondaryAlignment=FALSE, 
                                            isDuplicate=FALSE),
                        which=range,
                        mapqFilter=1)
    ## read alignment
    sub_alignment = readGAlignments(bam,param=param)
    ## calculate coverage
    cov = GenomicAlignments::coverage(sub_alignment)
    cov = cov[range]
    ## return average coverage for each region
    round(mean(cov))
}

## helper function to prepare coverage and gc data
## given the path to targeted bed file and bam file, 
## create a GRanges object containing coverage for each targeted region
getCoverage = function(
    bam, 
    target_bed, 
    genome_assembly="hg19"){
    ## read in target bed table
    target_gr = rtracklayer::import(target_bed)
    if(nchar(seqlevels(target_gr)[1])>3){
        seqlevels(target_gr,pruning.mode="coarse")=c("chr1","chr2","chr3","chr4","chr5",
                                            "chr6","chr7","chr8","chr9","chr10",
                                            "chr11","chr12","chr13","chr14",
                                            "chr15","chr16","chr17","chr18",
                                            "chr19","chr20","chr21","chr22",
                                            "chrX","chrY")
    }
    else{
        seqlevels(target_gr,pruning.mode="coarse")=c("1","2","3","4","5",
                                            "6","7","8","9","10",
                                            "11","12","13","14",
                                            "15","16","17","18",
                                            "19","20","21","22",
                                            "X","Y")
    }
    target_gr = sort(target_gr)
    # remove regions overlapped with REs
    #target_gr = removeRE(target_gr,genome_assembly)
    target_gr = removeGap(target_gr,genome_assembly)
    target_gr = removeHLA(target_gr,genome_assembly)
    target_gr = removeAQP(target_gr,genome_assembly)
    nRegion = length(target_gr)
    cat(paste(nRegion, "non-repeats regions from", length(seqlevels(target_gr)),
                "chromosomes in the bed file.", sep=" "))
    ## use helper function to calculate average coverage for each region, 
    ## in order to handle large bam files, 
    ## process 1000 regions at a time to reduce memory usage
    message("calculating depth from BAM...")
    depth = NULL
    for (i in seq(1,nRegion,1000)){
        ## report progress
        if(i%%5000==1&i>1) cat(paste(i-1,"regions processed\n"))
        end = ifelse(i+999>nRegion,nRegion,i+999)
        sub_depth = calculateSubCoverage(target_gr[i:end],bam)
        depth = c(depth, sub_depth)
    }
    ## see if number of depth equals to number of regions
    if (length(depth) == nRegion) mcols(target_gr)$depth = depth
    else stop(paste("with", nRegion, "target regions, only", 
                    length(depth), "processed. Please check your input.",
                    sep=" "))
    target_gr
}


## helper function to prepare gc data
## given targets as a GRanges object, calculate gc content for each range
calculateGC = function(
    range,
    genome_assembly="hg19"){
    genome = getBSgenome(genome_assembly)
    ## use alphabetFrequency function in biostring to calculate GC percent
    message("calculating GC content...")
    base_frequency = alphabetFrequency(BSgenomeViews(genome,range),
                                        as.prob = TRUE)[,c("C","G")]
    gc_content = apply(base_frequency,1,sum)
    gc_content
}


## helper function to quantile normalize coverage if there is >1 sample
## given a GRangesList, normalize the coverage by quantile normalization
coverageQuantile = function(
    object){
    message(paste("Quantile normalizing ..."))
    nSample = length(object)
    sample_name = names(object)
    all_cov = NULL
    for (i in 1:nSample){
        all_cov = cbind(all_cov,mcols(object[[i]])$depth)
    }
    all_quantile = round(normalize.quantiles(all_cov))
    res = NULL
    for (i in 1:nSample){
        sub_res = object[[i]]
        mcols(sub_res)$quantiled_depth = all_quantile[,i]
        if (is.null(res)) res = GRangesList(sub_res)
        else
            res = c(res,GRangesList(sub_res))
    }
    names(res) = sample_name
    res
}

## helper function to correct coverage by GC content
## given a GRanges object, output corrected coverage
correctGCBias = function(
    object,
    plot=TRUE){
    ## correct coverage by GC content
    ## convert GRanges object to frame
    gc_depth = as.data.frame(object)
    name = names(gc_depth)
    
    ## check if data has been quantile normalized
    ## if data has been quantile normalized, following analysis is operated
    ## on quantiled depth
    quantiled = FALSE
    if (is.element("quantiled_depth",name)){
        ## exclude regions with 0 coverage
        quantiled = TRUE
        gc_depth = gc_depth[gc_depth$depth>0&gc_depth$quantiled_depth>0,]
        names(gc_depth) = sub("quantiled_depth","coverage",name)
    }
    else{
        gc_depth = gc_depth[gc_depth$depth>0,]
        names(gc_depth) = sub("depth","coverage",name)
    }
    
    ## round gc content to 0.001 increments
    gc_depth = data.frame(gc_depth,round_gc=round(gc_depth$GC,3))
    ## split data by GC content
    split_gc = split(gc_depth,gc_depth$round_gc)
    coverage_by_gc = sapply(split_gc,function(x)mean(x$coverage,na.rm=TRUE))
    gc_coverage = data.frame(round_gc = as.numeric(names(coverage_by_gc)),
                            mean_reads = coverage_by_gc)
    ## fit coverage and GC content by loess
    gc_coverage_fit = stats::loess(gc_coverage$mean_reads~gc_coverage$round_gc,
                            span=0.5)
    ## the expected coverage is the mean of the raw coverage
    expected_coverage = mean(gc_depth[,"coverage"])
    
    ## plot GC vs. raw reads plot
    if(plot == TRUE){
        plot(x = gc_coverage$round_gc, 
            y = gc_coverage$mean_reads, 
            pch = 16, col = "blue", cex = 0.6, 
            ylim = c(0,1.5*quantile(gc_coverage$mean_reads,0.95,na.rm=TRUE)),
            xlab = "GC content", ylab = "raw reads", 
            main = "GC vs Coverage Before Norm",cex.main=0.8)
        graphics::lines(gc_coverage$round_gc, 
            stats::predict(gc_coverage_fit, gc_coverage$round_gc), 
            col = "red", lwd = 2)
        graphics::abline(h = expected_coverage, lwd = 2, col = "grey", lty = 3)
    }
    
    ## correct reads by loess fit
    normed_coverage = NULL
    for (i in 1:24){
        ## check if the coordinate is with "chr" or not
        if(nchar(as.character(seqnames(object)@values[1]))>3) {
            chr = paste("chr",i,sep="")
            if (i == 23) chr = "chrX"
            if (i == 24) chr = "chrY"
        }
        else{
            chr = i
            if (i == 23) chr = "X"
            if (i == 24) chr = "Y"
        }
        tmp_chr = gc_depth[gc_depth$seqnames == chr,]
        if(nrow(tmp_chr)==0) next
        chr_normed = NULL
        for (j in 1:nrow(tmp_chr)){
            tmp_coverage = tmp_chr[j,"coverage"]
            tmp_GC = tmp_chr[j,"GC"]
            # predicted read from the loess fit
            tmp_predicted = stats::predict(gc_coverage_fit, tmp_GC)
            # calculate the error biased from expected
            tmp_error = tmp_predicted - expected_coverage
            tmp_normed = tmp_coverage - tmp_error
            chr_normed = c(chr_normed, tmp_normed)
        }
        normed_coverage = c(normed_coverage,chr_normed)
    }
    gc_depth = cbind(gc_depth,normed_coverage = normed_coverage)
    gc_depth = gc_depth[!is.na(gc_depth$normed_coverage),]
    
    ## calculate and plot GC vs coverage after normalization
    split_gc_after = split(gc_depth,gc_depth$round_gc)
    coverage_by_gc_after = sapply(split_gc_after,
                                function(x)mean(x$normed_coverage,
                                                na.rm=TRUE))
    gc_coverage_after=data.frame(round_gc=
                                    as.numeric(names(coverage_by_gc_after)),
                                mean_reads=coverage_by_gc_after)
    gc_coverage_fit_after = stats::loess(gc_coverage_after$mean_reads
                                ~gc_coverage_after$round_gc,span=0.5)
    
    ## plot GC vs coverage after normalization
    if (plot == TRUE){
        plot(x = gc_coverage_after$round_gc, 
            y = gc_coverage_after$mean_reads, 
            pch = 16, col = "blue", cex = 0.6, 
            ylim = c(0,1.5*quantile(gc_coverage_after$mean_reads,0.95,
                                    na.rm=TRUE)),
            xlab = "GC content", ylab = "normalized reads", 
            main = "GC vs Coverage After Norm",cex.main=0.8)
        graphics::lines(gc_coverage_after$round_gc, 
            stats::predict(gc_coverage_fit_after, gc_coverage_after$round_gc),
            col = "red", lwd = 2)
    }
    
    ## round normalized coverage to integer
    gc_depth$normed_coverage = round(gc_depth$normed_coverage)
    ## exclude regions with corrected coverage <0
    gc_depth = gc_depth[gc_depth$normed_coverage>0,]
    
    ## convert gc_depth into a GRanges object
    if (quantiled == TRUE){
        res = GRanges(seqnames = Rle(gc_depth$seqnames), 
                    ranges = IRanges(start=gc_depth$start,end=gc_depth$end),
                    strand = rep("*",nrow(gc_depth)),
                    depth = gc_depth$depth,
                    quantiled_depth = gc_depth$coverage,
                    GC = gc_depth$GC,
                    normed_depth = gc_depth$normed_coverage)
    }
    else{
        res = GRanges(seqnames = Rle(gc_depth$seqnames), 
                    ranges = IRanges(start=gc_depth$start,end=gc_depth$end),
                    strand = rep("*",nrow(gc_depth)),
                    depth = gc_depth$coverage,
                    GC = gc_depth$GC,
                    normed_depth = gc_depth$normed_coverage)
    }
    res = res[!is.na(mcols(res)$normed_depth)]
    res
}


## function to calculate mean coverage for each chromosome after normalization
## and could plot out the coverage before and after normalization
## input: a GRangesList object
calculateNormedCoverage = function(
    object,
    plot=TRUE){
    if(nchar(seqlevels(object)[1])>3){
        chr_name=c("chr1","chr2","chr3","chr4","chr5",
                    "chr6","chr7","chr8","chr9","chr10",
                    "chr11","chr12","chr13","chr14",
                    "chr15","chr16","chr17","chr18",
                    "chr19","chr20","chr21","chr22",
                    "chrX","chrY")
    }
    else{
        chr_name = c("1","2","3","4","5","6","7","8","9","10","11","12",
                     "13","14","15","16","17","18","19","20","21","22","X","Y")
    }
    nSample = length(object)
    sample_name = names(object)
    split_object = sapply(object,function(x)split(x,seqnames(x)))
    
    ## calculate average coverage for each chromosome after normalization
    after_chr = NULL
    for (i in 1:nSample){
        sub_after_chr = sapply(split_object[[i]],
                                function(x)mean(mcols(x)$normed_depth))
        after_chr = rbind(after_chr,sub_after_chr[chr_name])
    }
    rownames(after_chr) = sample_name
    after_chr = replace(after_chr,is.nan(after_chr),0)
    
    ## if plot requested, then plot 
    if (plot == TRUE){
        graphics::par(mfrow=c(ifelse(nSample>1,3,2),1))
        ## calculate average coverage before normalization
        before_chr = NULL
        quantiled_chr = NULL
        for (i in 1:nSample){
            sub_before_chr = sapply(split_object[[i]],
                                    function(x)mean(mcols(x)$depth))
            before_chr = rbind(before_chr,sub_before_chr[chr_name])
            if (nSample>1){
                sub_quantiled_chr = sapply(split_object[[i]],
                                            function(x)
                                                mean(mcols(x)$quantiled_depth))
                quantiled_chr=rbind(quantiled_chr,sub_quantiled_chr[chr_name])
            }
        }
        before_chr = replace(before_chr,is.nan(before_chr),0)
        quantiled_chr = replace(quantiled_chr,is.nan(quantiled_chr),0)
        ## plot
        cols = sample(grDevices::colors(),nSample,replace = TRUE)
        nChr = ncol(after_chr)
        ## 1. plot raw coverage
        plot(1:nChr,rep(1,nChr),type="n",
            ylim=c(0.5*min(before_chr,na.rm=TRUE),
                    1.5*max(before_chr,na.rm=TRUE)),
            xlab="chromosome",ylab="average coverage",
            main = "raw data",xaxt="n")
        graphics::axis(1,at=seq(1,nChr),chr_name[1:nChr],las=2)
        for (i in 1:nSample){
            graphics::lines(1:nChr,before_chr[i,],type="b",pch=16,col=cols[i])
        }
        graphics::legend("topright",sample_name,pch=16,col=cols,
                        ncol=ceiling(nSample/5),cex=0.6)
        
        if(nSample>1){
            ## 2. plot quantiled coverage
            plot(1:nChr,rep(1,nChr),type="n",xaxt="n",
                ylim=c(0.5*min(quantiled_chr,na.rm=TRUE),
                        1.5*max(quantiled_chr,na.rm=TRUE)),
                xlab="chromosome",ylab="average coverage",
                main="quantile normalized")
            graphics::axis(1,at=seq(1,nChr),chr_name[1:nChr],las=2)
            for (i in 1:nSample){
                graphics::lines(1:nChr,quantiled_chr[i,],type="b",
                                pch=16,col=cols[i])
            }
            graphics::legend("topright",sample_name,pch=16,col=cols,
                            ncol=ceiling(nSample/5),cex=0.6)
        }
        
        ## 3. plot normed coverage
        plot(1:nChr,rep(1,nChr),type="n",xaxt="n",
            ylim=c(0.5*min(after_chr,na.rm=TRUE),1.5*max(after_chr,na.rm=TRUE)),
            xlab="chromosome",ylab="average coverage",main="GC normalized")
        graphics::axis(1,at=seq(1,nChr),chr_name[1:nChr],las=2)
        for (i in 1:nSample){
            graphics::lines(1:nChr,after_chr[i,],type="b",pch=16,col=cols[i])
        }
        graphics::legend("topright",sample_name,pch=16,col=cols,
                         ncol=ceiling(nSample/5),cex=0.6)
    }
    after_chr
}


######################## Prepare for AAF ##########################
## filters set for vcf file
isHetero = function(x){
    genotype = geno(x)$GT
    genotype == "0/1" | genotype == "1/0"
}


## remove SNPs overlapping with gap
removeGap = function(gr,genome){
    # 1. load the correct gap info for input genome
    if(length(grep("19",genome))>0){
        path = system.file("gap","hg19_gap_gr.RDS",package="MADSEQ")
        gap_gr = readRDS(path)
    }
    else if(length(grep("37",genome))>0){
        path = system.file("gap","hs37d5_gap_gr.RDS",package="MADSEQ")
        gap_gr = readRDS(path)
    }
    else if(length(grep("38",genome))>0){
        path = system.file("gap","hg38_gap_gr.RDS",package="MADSEQ")
        gap_gr = readRDS(path)
    }
    
    ov = findOverlaps(gr,gap_gr)
    if(length(ov)==0){
        res_degap = gr
    }
    else
        res_degap = gr[-queryHits(ov)]
    res_degap
}

## remove SNPs inside the HLA region on chr6
# because of the variability of HLA regions, 
# variant calling for this region is problematic most of the time, 
# to keep a clean result, we will filter out SNPs called within this region
# padded 1000kb up and downstream of HLA region

removeHLA = function(gr,genome){
    # 1. load the HLA coordinates for the input genome
    if(length(grep("19",genome))>0){
        path = system.file("HLA","hg19_HLA_gr.RDS",package="MADSEQ")
        HLA_gr = readRDS(path)
    }
    else if(length(grep("37",genome))>0){
        path = system.file("HLA","hs37d5_HLA_gr.RDS",package="MADSEQ")
        HLA_gr = readRDS(path)
    }
    else if(length(grep("38",genome))>0){
        path = system.file("HLA","hg38_HLA_gr.RDS",package="MADSEQ")
        HLA_gr = readRDS(path)
    }
    
    ov = findOverlaps(gr,HLA_gr)
    
    if(length(ov)==0){
        res_deHLA = gr
    }
    else
        res_deHLA = gr[-queryHits(ov)]
    res_deHLA
}

## remove SNPs inside the AQP7 region on chr9
# because of the variability of AQP7, 
# variant calling for this region is problematic most of the time, 
# to keep a clean result, we will filter out SNPs called within this region
# padded 1000kb up and downstream of AQP7 region
removeAQP = function(gr,genome){
    # 1. load the AQP7 coordinates for the input genome
    if(length(grep("19",genome))>0){
        path = system.file("AQP7","hg19_AQP7_gr.RDS",package="MADSEQ")
        AQP7_gr = readRDS(path)
    }
    else if(length(grep("37",genome))>0){
        path = system.file("AQP7","hs37d5_AQP7_gr.RDS",package="MADSEQ")
        AQP7_gr = readRDS(path)
    }
    else if(length(grep("38",genome))>0){
        path = system.file("AQP7","hg38_AQP7_gr.RDS",package="MADSEQ")
        AQP7_gr = readRDS(path)
    }
    
    ov = findOverlaps(gr,AQP7_gr)
    
    if(length(ov)==0){
        res_deAQP7 = gr
    }
    else
        res_deAQP7 = gr[-queryHits(ov)]
    res_deAQP7
}

## remove coverage inside the repetitive regions (RE)
# because of multimappability in REs
# mapping depth for these regions can be not accurate, 
# to keep a clean result, we will filter out regions overlapped with RE
removeRE = function(gr,genome){
    # 1. load the HLA coordinates for the input genome
    if(length(grep("19",genome))>0){
        path = system.file("RE","hg19_RE_gr.RDS",package="MADSEQ")
        RE_gr = readRDS(path)
    }
    else if(length(grep("37",genome))>0){
        path = system.file("RE","hg19_RE_gr.RDS",package="MADSEQ")
        RE_gr = readRDS(path)
        seqlevelsStyle(RE_gr) = "ncbi"
    }
    else if(length(grep("38",genome))>0){
        path = system.file("RE","hg38_RE_gr.RDS",package="MADSEQ")
        RE_gr = readRDS(path)
    }
    
    ov = findOverlaps(gr,RE_gr)
    
    if(length(ov)==0){
        res_deRE = gr
    }
    else
        res_deRE = gr[-queryHits(ov)]
    res_deRE
}


## remove regions with densed biased SNPs (usually regions around gaps/SVs)
filter_hetero = function(data,binsize=10,plot=TRUE){
    seqnames = unique(seqnames(data))
    
    for (seq_num in 1:length(seqnames)){
        tmp_seq = seqnames[seq_num]
        chr = data[seqnames(data)==tmp_seq]
        
        # calculate AAF in bin
        AAF = mcols(chr)$Alt_D/mcols(chr)$DP
        bin_start = seq(1,length(AAF)+binsize,binsize)
        bin_end = (bin_start-1)[-1]
        bin_end[length(bin_end)] = length(AAF) 
        bin = data.frame(start=bin_start[1:length(bin_start)-1],end=bin_end)
        
        if(nrow(bin)>0){
            AAF_bin = apply(bin,1,function(x)mean(AAF[x[1]:x[2]]))
            bin$AAF = AAF_bin
            
            binned_AAF = rep(NA,length(chr))
            for (i in 1:nrow(bin)){
                tmp = bin[i,,drop=FALSE]
                binned_AAF[c(tmp[1,1]:tmp[1,2])] = tmp[1,3]
            }
            mcols(chr)$AAF = AAF
            mcols(chr)$binned_AAF1 = binned_AAF
        }
        else mcols(chr)$binned_AAF1 = 0
        
        
        # sliding window
        sliding_size = round(binsize/2)
        bin2 = data.frame(start=bin$start+sliding_size,end=bin$end+sliding_size)
        bin2 = bin2[bin2$end<length(AAF),]
        
        if(nrow(bin2)>0){
            AAF_bin2 = apply(bin2,1,function(x)mean(AAF[x[1]:x[2]]))
            bin2$AAF = AAF_bin2
            
            binned_AAF2 = rep(NA,length(chr))
            for (i in 1:nrow(bin2)){
                tmp = bin2[i,,drop=FALSE]
                binned_AAF2[c(tmp[1,1]:tmp[1,2])] = tmp[1,3]
            }
            binned_AAF2 = ifelse(is.na(binned_AAF2),binned_AAF,binned_AAF2)
            mcols(chr)$binned_AAF2 = binned_AAF2
        }
        else mcols(chr)$binned_AAF2 = 0
        
        if(quantile(c(AAF_bin,AAF_bin2),0.05)<0.4|quantile(c(AAF_bin,AAF_bin2),0.95)>0.58){
            limit_low = quantile(c(AAF_bin,AAF_bin2),0.01)
            limit_high = quantile(c(AAF_bin,AAF_bin2),0.99)
        }
        else{
            limit_low = min(max(0.35,quantile(c(AAF_bin,AAF_bin2),0.02)),0.4)
            limit_high = max(min(0.65,quantile(c(AAF_bin,AAF_bin2),0.98)),0.6)
        }
        keep_idx = mcols(chr)$binned_AAF1>=limit_low&mcols(chr)$binned_AAF1<=limit_high&mcols(chr)$binned_AAF2>=limit_low&mcols(chr)$binned_AAF2<=limit_high
        chr_f = chr[keep_idx]
        
        if (seq_num==1){
            res = chr_f
        }
        else res = c(res,chr_f)
        
        if (plot==TRUE){
            par(mfrow=c(3,1))
            if(length(chr)>=1){
                plot(start(chr),mcols(chr)$AAF,pch=16,cex=0.5,ylim=c(0,1),
                    xlab=tmp_seq,ylab="AAF",main="before",xlim=c(0,max(start(chr))))
                dup = duplicated(mcols(chr)$binned_AAF1)
                reduced_chr = chr[!dup]
                points(start(reduced_chr),mcols(reduced_chr)$binned_AAF1,
                    pch=16,col="red",cex=0.6)
                points(start(reduced_chr),mcols(reduced_chr)$binned_AAF2,
                    pch=16,col="blue",cex=0.6)
            }
            
            if(length(chr_f)>=1){
                plot(start(chr_f),mcols(chr_f)$AAF,pch=16,cex=0.5,ylim=c(0,1),
                    xlab=tmp_seq,ylab="AAF",main="after",xlim=c(0,max(start(chr))))
            }
            
            chr_remove = chr[!keep_idx]
            if(length(chr_remove)>=1){
                plot(start(chr_remove),mcols(chr_remove)$AAF,pch=16,cex=0.5,ylim=c(0,1),
                    xlab=tmp_seq,ylab="AAF",main="removed",xlim=c(0,max(start(chr))))
                dup = duplicated(mcols(chr_remove)$binned_AAF1)
                reduced_chr_remove = chr_remove[!dup]
                points(start(reduced_chr_remove),mcols(reduced_chr_remove)$binned_AAF1,
                    pch=16,col="red",cex=0.6)
                points(start(reduced_chr_remove),mcols(reduced_chr_remove)$binned_AAF2,
                    pch=16,col="blue",cex=0.6)
            }
        }
    }
    
    res
}


