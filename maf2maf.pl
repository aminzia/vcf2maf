#!/usr/bin/env perl

# maf2maf - Reannotate the effects of variants in a MAF by running maf2vcf followed by vcf2maf

use strict;
use warnings;
use IO::File;
use Getopt::Long qw( GetOptions );
use Pod::Usage qw( pod2usage );
use File::Temp qw( tempdir );
use File::Copy qw( move );
use File::Path qw( mkpath rmtree );
use File::Basename;
use Cwd 'abs_path';
use Config;

# Set any default paths and constants
my ( $tum_depth_col, $tum_rad_col, $tum_vad_col ) = qw( t_depth t_ref_count t_alt_count );
my ( $nrm_depth_col, $nrm_rad_col, $nrm_vad_col ) = qw( n_depth n_ref_count n_alt_count );
my ( $vep_path, $vep_data, $vep_forks, $ref_fasta ) = ( "/ssd-data/cmo/opt/vep/v79", "/ssd-data/cmo/opt/vep/v79", 4,
    "/ssd-data/cmo/opt/vep/v79/homo_sapiens/79_GRCh37/Homo_sapiens.GRCh37.75.dna.primary_assembly.fa" );
my $perl_bin = $Config{perlpath};

# Columns that can be safely borrowed from the input MAF
my $retain_cols = "Center,Verification_Status,Validation_Status,Mutation_Status,Sequencing_Phase" .
    ",Sequence_Source,Validation_Method,Score,BAM_file,Sequencer,Tumor_Sample_UUID" .
    ",Matched_Norm_Sample_UUID";

# Columns that should never be overridden since they are results of re-annotation
my %force_new_cols = map{ my $c = lc; ( $c, 1 )} qw( Hugo_Symbol Entrez_Gene_Id NCBI_Build
    Chromosome Start_Position End_Position Strand Variant_Classification Variant_Type
    Reference_Allele Tumor_Seq_Allele1 Tumor_Seq_Allele2 Tumor_Sample_Barcode
    Matched_Norm_Sample_Barcode Match_Norm_Seq_Allele1 Match_Norm_Seq_Allele2
    Tumor_Validation_Allele1 Tumor_Validation_Allele2 Match_Norm_Validation_Allele1
    Match_Norm_Validation_Allele2 HGVSc HGVSp HGVSp_Short Transcript_ID Exon_Number t_depth
    t_ref_count t_alt_count n_depth n_ref_count n_alt_count all_effects Allele Gene Feature
    Feature_type Consequence cDNA_position CDS_position Protein_position Amino_acids Codons
    Existing_variation ALLELE_NUM DISTANCE STRAND SYMBOL SYMBOL_SOURCE HGNC_ID BIOTYPE CANONICAL
    CCDS ENSP SWISSPROT TREMBL UNIPARC RefSeq SIFT PolyPhen EXON INTRON DOMAINS GMAF AFR_MAF
    AMR_MAF ASN_MAF EUR_MAF AA_MAF EA_MAF CLIN_SIG SOMATIC PUBMED MOTIF_NAME MOTIF_POS
    HIGH_INF_POS MOTIF_SCORE_CHANGE );

# Check for missing or crappy arguments
unless( @ARGV and $ARGV[0]=~m/^-/ ) {
    pod2usage( -verbose => 0, -message => "$0: Missing or invalid arguments!\n", -exitval => 2 );
}

# Parse options and print usage syntax on a syntax error, or if help was explicitly requested
my ( $man, $help ) = ( 0, 0 );
my ( $input_maf, $output_maf, $tmp_dir );
my ( $force_reannotation ) = ( 0 );
GetOptions(
    'help!' => \$help,
    'man!' => \$man,
    'input-maf=s' => \$input_maf,
    'output-maf=s' => \$output_maf,
    'force-re-annotation' => \$force_reannotation,
    'tmp-dir=s' => \$tmp_dir,
    'tum-depth-col=s' => \$tum_depth_col,
    'tum-rad-col=s' => \$tum_rad_col,
    'tum-vad-col=s' => \$tum_vad_col,
    'nrm-depth-col=s' => \$nrm_depth_col,
    'nrm-rad-col=s' => \$nrm_rad_col,
    'nrm-vad-col=s' => \$nrm_vad_col,
    'retain-cols=s' => \$retain_cols,
    'vep-path=s' => \$vep_path,
    'vep-data=s' => \$vep_data,
    'vep-forks=s' => \$vep_forks,
    'ref-fasta=s' => \$ref_fasta,
) or pod2usage( -verbose => 1, -input => \*DATA, -exitval => 2 );
pod2usage( -verbose => 1, -input => \*DATA, -exitval => 0 ) if( $help );
pod2usage( -verbose => 2, -input => \*DATA, -exitval => 0 ) if( $man );

# Locate the maf2vcf and vcf2maf scripts that should be next to this script
my ( $script_dir ) = $0 =~ m/^(.*)\/maf2maf/;
$script_dir = "." unless( $script_dir );
my ( $maf2vcf_path, $vcf2maf_path ) = ( "$script_dir/maf2vcf.pl", "$script_dir/vcf2maf.pl" );
( -s $maf2vcf_path ) or die "ERROR: Couldn't locate maf2vcf.pl! Must be beside maf2maf.pl\n";
( -s $vcf2maf_path ) or die "ERROR: Couldn't locate vcf2maf.pl! Must be beside maf2maf.pl\n";

# Create a temporary directory for our intermediate files, unless the user wants to use their own
if( $tmp_dir ) {
    if( $force_reannotation ) {
        rmtree( $tmp_dir );
        mkpath( $tmp_dir );
    }
    elsif( !-d $tmp_dir ) {
        die "ERROR: $tmp_dir is not a directory.\n";
    }
}
else {
    $tmp_dir = tempdir( CLEANUP => 1 );
}

# Get absolute path of the input maf file.
my ( $maf_name, $maf_path ) = fileparse( abs_path( $input_maf ) );

# Check if the input maf file was annotated before by comparing file dates and md5sums
if ( $output_maf && -s $output_maf && -s $input_maf && !$force_reannotation && -s "$tmp_dir/summary.txt" ){
    my $maf_last_update = `grep $maf_path$maf_name $tmp_dir/summary.txt`;
    if ( $maf_last_update ) {
        # Get md5sums and dates of previous input and output files
        chomp $maf_last_update;
        my ( $last_inMaf, $last_inMaf_md5sum, $last_inMaf_date, $last_outMaf, $last_outMaf_md5sum, $last_outMaf_date ) = split( /\t/, $maf_last_update );
        
        # Current md5sums and dates of input and output files
        my ( $out_name, $out_path ) = fileparse( abs_path( $output_maf ) );
    
        my $input_maf_date    = `ls --full-time $input_maf  | awk \047\{print \$6" "substr(\$7,1,8)\}\047`;
        my $output_maf_date   = `ls --full-time $output_maf | awk \047\{print \$6" "substr(\$7,1,8)\}\047`;
        my $input_maf_md5sum  = `grep -v "^#" $input_maf  | md5sum | awk \047\{print \$1\}\047`;
        my $output_maf_md5sum = `grep -v "^#" $output_maf | md5sum | awk \047\{print \$1\}\047`;
        chomp $input_maf_date;
        chomp $output_maf_date;
        chomp $input_maf_md5sum;
        chomp $output_maf_md5sum;
    
        if( ( $last_inMaf eq "$maf_path$maf_name" && $last_outMaf eq "$out_path$out_name" ) &&
            ( $last_inMaf_md5sum eq $input_maf_md5sum   || $last_inMaf_date eq $input_maf_date ) &&
            ( $last_outMaf_md5sum eq $output_maf_md5sum || $last_outMaf_date eq $output_maf_date ) ){
            warn "WARNING: Annotated MAF already exists ($output_maf). Skipping re-annotation.\n";
            exit 0;
        }
    }
}

# Contruct a maf2vcf command and run it
my $maf2vcf_cmd = "$perl_bin $maf2vcf_path --input-maf $input_maf --output-dir $tmp_dir " .
    "--ref-fasta $ref_fasta --tum-depth-col $tum_depth_col --tum-rad-col $tum_rad_col " .
    "--tum-vad-col $tum_vad_col --nrm-depth-col $nrm_depth_col --nrm-rad-col $nrm_rad_col ".
    "--nrm-vad-col $nrm_vad_col";
system( $maf2vcf_cmd ) == 0 or die "\nERROR: Failed to run maf2vcf!\nCommand: $maf2vcf_cmd\n";

my $maf_name_prefix = $maf_path;
$maf_name_prefix =~ s/\//_/g;

# For each VCF generated by maf2vcf above, contruct a vcf2maf command and run it
my @vcfs = grep{ !m/.vep.vcf$/ } glob( "$tmp_dir/$maf_name_prefix*.vcf" ); # Avoid reannotating annotated VCFs
foreach my $tn_vcf ( @vcfs ) {
    my ( $tumor_id, $normal_id ) = $tn_vcf=~m/^.*\/$maf_name_prefix(.*)_vs_(.*)\.vcf/;
    my $tn_maf = $tn_vcf;
    $tn_maf =~ s/.vcf$/.vep.maf/;
    my $vcf2maf_cmd = "$perl_bin $vcf2maf_path --input-vcf $tn_vcf --output-maf $tn_maf " .
        "--tumor-id $tumor_id --normal-id $normal_id --vep-path $vep_path --vep-data $vep_data " .
        "--vep-forks $vep_forks --ref-fasta $ref_fasta";
    system( $vcf2maf_cmd ) == 0 or die "\nERROR: Failed to run vcf2maf!\nCommand: $vcf2maf_cmd\n";
    `rm $tn_vcf`;
}

# Fetch the column header from one of the resulting MAFs
my @mafs = glob( "$tmp_dir/$maf_name_prefix*.vep.maf" );
my $maf_header = `grep ^Hugo_Symbol $mafs[0]`;
chomp( $maf_header );

# If user wants to retain some columns from the input MAF, fetch those and override
my %input_maf_data = ();
if( $retain_cols ) {

    # Parse the input MAF and fetch the data for columns that we need to retain/override
    my $input_maf_fh = IO::File->new( $input_maf ) or die "ERROR: Couldn't open file: $input_maf\n";
    my %input_maf_col_idx = (); # Hash to map column names to column indexes
    while( my $line = $input_maf_fh->getline ) {

        next if( $line =~ m/^#/ ); # Skip comments

        # Do a thorough removal of carriage returns, line feeds, prefixed/suffixed whitespace
        my @cols = map{s/^\s+|\s+$|\r|\n//g; $_} split( /\t/, $line );

        # Parse the header line to map column names to their indexes
        if( $line =~ m/^(Hugo_Symbol|Chromosome)/ ) {
            my $idx = 0;
            map{ my $c = lc; $input_maf_col_idx{$c} = $idx; ++$idx } @cols;

            # Check if retaining columns not in old MAF, or that we shouldn't override in new MAF
            foreach my $c ( split( ",", $retain_cols )) {
                my $c_lc = lc( $c );
                if( !defined $input_maf_col_idx{$c_lc} ){
                    warn "WARNING: Column '$c' not found in old MAF.\n";
                }
                elsif( $force_new_cols{$c_lc} ){
                    warn "WARNING: Column '$c' cannot be overridden in new MAF.\n";
                }
            }
        }
        else {
            # Figure out which of the tumor alleles is non-reference
            my ( $ref, $al1, $al2 ) = map{ my $c = lc; $cols[$input_maf_col_idx{$c}] } qw( Reference_Allele Tumor_Seq_Allele1 Tumor_Seq_Allele2 );
            my $var_allele = ( defined $al1 and $al1 ne $ref ? $al1 : $al2 );

            # Create a key for this variant using Chromosome:Start_Position:Tumor_Sample_Barcode:Reference_Allele:Variant_Allele
            my $key = join( ":", ( map{ my $c = lc; $cols[$input_maf_col_idx{$c}] } qw( Chromosome Start_Position Tumor_Sample_Barcode Reference_Allele )), $var_allele );

            # Store values for this variant into a hash, adding column names to the key
            foreach my $c ( map{lc} split( ",", $retain_cols )) {
                $input_maf_data{$key}{$c} = "";
                if( defined $input_maf_col_idx{$c} and defined $cols[$input_maf_col_idx{$c}] ) {
                    $input_maf_data{$key}{$c} = $cols[$input_maf_col_idx{$c}];
                }
            }
        }
    }
    $input_maf_fh->close;

    # Add additional column headers for the output MAF, if any
    my %maf_cols = map{ my $c = lc; ( $c, 1 )} split( /\t/, $maf_header );
    my @addl_maf_cols = grep{ my $c = lc; !$maf_cols{$c} } split( ",", $retain_cols );
    map{ $maf_header .= "\t$_" } @addl_maf_cols;

    # Retain/override data in each of the per-TN-pair MAFs
    foreach my $tn_maf ( @mafs ) {
        my $tn_maf_fh = IO::File->new( $tn_maf ) or die "ERROR: Couldn't open file: $tn_maf\n";
        my %output_maf_col_idx = (); # Hash to map column names to column indexes
        my $tmp_tn_maf_fh = IO::File->new( "$tn_maf.tmp", ">" ) or die "ERROR: Couldn't open file: $tn_maf.tmp\n";
        while( my $line = $tn_maf_fh->getline ) {

            # Do a thorough removal of carriage returns, line feeds, prefixed/suffixed whitespace
            my @cols = map{ s/^\s+|\s+$|\r|\n//g; $_ } split( /\t/, $line );

            # Copy comment lines to the new MAF unchanged
            if( $line =~ m/^#/ ) {
                $tmp_tn_maf_fh->print( $line );
            }
            # Print the MAF header prepared earlier, but also create a hash with column indexes
            elsif( $line =~ m/^Hugo_Symbol/ ) {
                my $idx = 0;
                map{ my $c = lc; $output_maf_col_idx{$c} = $idx; ++$idx } ( @cols, @addl_maf_cols );
                $tmp_tn_maf_fh->print( "$maf_header\n" );
            }
            # For all other lines, insert the data collected from the original input MAF
            else {
                my $key = join( ":", map{ my $c = lc; $cols[$output_maf_col_idx{$c}] } qw( Chromosome Start_Position Tumor_Sample_Barcode Reference_Allele Tumor_Seq_Allele2 ));
                foreach my $c ( map{lc} split( /\t/, $maf_header )){
                    if( !$force_new_cols{$c} and defined $input_maf_data{$key}{$c} ) {
                        $cols[$output_maf_col_idx{$c}] = $input_maf_data{$key}{$c};
                    }
                }
                $tmp_tn_maf_fh->print( join( "\t", @cols ) . "\n" );
            }
        }
        $tmp_tn_maf_fh->close;
        $tn_maf_fh->close;

        # Overwrite the old MAF with the new one containing data from the original input MAF
        move( "$tn_maf.tmp", $tn_maf );
    }
}

# Concatenate the per-TN-pair MAFs into the user-specified final MAF
# Default to printing to screen if an output MAF was not defined
my $maf_fh = *STDOUT;
if( $output_maf ) {
    $maf_fh = IO::File->new( $output_maf, ">" ) or die "ERROR: Couldn't open file: $output_maf\n";
}
$maf_fh->print( "#version 2.4\n$maf_header\n" );
foreach my $tn_maf ( @mafs ) {
    my @maf_lines = `egrep -v "^#|^Hugo_Symbol" $tn_maf`;
    $maf_fh->print( @maf_lines );
    `rm $tn_maf`;
}
$maf_fh->close;

# Keep a record of file names, md5sum, and dates of current vep annotation
if ( $output_maf && -s $output_maf ){
    my $input_maf_date    = `ls --full-time $input_maf  | awk \047\{print \$6" "substr(\$7,1,8)\}\047`;
    my $output_maf_date   = `ls --full-time $output_maf | awk \047\{print \$6" "substr(\$7,1,8)\}\047`;
    my $input_maf_md5sum  = `grep -v "^#" $input_maf  | md5sum | awk \047\{print \$1\}\047`;
    my $output_maf_md5sum = `grep -v "^#" $output_maf | md5sum | awk \047\{print \$1\}\047`;
    chomp $input_maf_date;
    chomp $output_maf_date;
    chomp $input_maf_md5sum;
    chomp $output_maf_md5sum;

    my ( $out_name, $out_path ) = fileparse( abs_path( $output_maf ) );
    my $out_str = "$maf_path$maf_name\t$input_maf_md5sum\t$input_maf_date\t$out_path$out_name\t$output_maf_md5sum\t$output_maf_date";

    if ( -s "$tmp_dir/summary.txt" && `grep $maf_path$maf_name $tmp_dir/summary.txt` ) {
        `sed -i 's|$maf_path$maf_name.*|$out_str|' $tmp_dir/summary.txt`;
    }
    else{
        `echo -e "$out_str" >> $tmp_dir/summary.txt`;
    }
}


__DATA__

=head1 NAME

 maf2maf.pl - Reannotate the effects of variants in a MAF by running maf2vcf followed by vcf2maf

=head1 SYNOPSIS

 perl maf2maf.pl --help
 perl maf2maf.pl --input-maf test.maf --output-maf test.vep.maf

=head1 OPTIONS

 --input-maf            Path to input file in MAF format
 --output-maf           Path to output MAF file [Default: STDOUT]
 --force-re-annotation  Delete tmp-dir if specified. Otherwise keep tmp-dir when program terminates
 --tmp-dir              Folder to retain intermediate VCFs/MAFs after runtime [Default: usually under /tmp]
 --tum-depth-col        Name of MAF column for read depth in tumor BAM [t_depth]
 --tum-rad-col          Name of MAF column for reference allele depth in tumor BAM [t_ref_count]
 --tum-vad-col          Name of MAF column for variant allele depth in tumor BAM [t_alt_count]
 --nrm-depth-col        Name of MAF column for read depth in normal BAM [n_depth]
 --nrm-rad-col          Name of MAF column for reference allele depth in normal BAM [n_ref_count]
 --nrm-vad-col          Name of MAF column for variant allele depth in normal BAM [n_alt_count]
 --retain-cols          Comma-delimited list of columns to retain from the input MAF [Center,Verification_Status,Validation_Status,Mutation_Status,Sequencing_Phase,Sequence_Source,Validation_Method,Score,BAM_file,Sequencer,Tumor_Sample_UUID,Matched_Norm_Sample_UUID]
 --vep-path             Folder containing variant_effect_predictor.pl [/ssd-data/cmo/opt/vep/v79]
 --vep-data             VEP's base cache/plugin directory [/ssd-data/cmo/opt/vep/v79]
 --vep-forks            Number of forked processes to use when running VEP [4]
 --ref-fasta            Reference FASTA file [/ssd-data/cmo/opt/vep/v79/homo_sapiens/79_GRCh37/Homo_sapiens.GRCh37.75.dna.primary_assembly.fa]
 --help                 Print a brief help message and quit
 --man                  Print the detailed manual

=head1 DESCRIPTION

This script runs a given MAF through maf2vcf to generate per-TN-pair VCFs in a temporary folder, and then runs vcf2maf on each VCF to reannotate variant effects and create a new combined MAF

=head1 AUTHORS

 Cyriac Kandoth (ckandoth@gmail.com)

=head1 LICENSE

 Apache-2.0 | Apache License, Version 2.0 | https://www.apache.org/licenses/LICENSE-2.0

=cut
