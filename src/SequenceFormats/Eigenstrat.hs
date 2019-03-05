{-# LANGUAGE OverloadedStrings #-}

{-|Module to read and parse Eigenstrat-formatted genotype data. The Eigenstrat format is defined at <https://github.com/argriffing/eigensoft/blob/master/CONVERTF/README>.

-}

module SequenceFormats.Eigenstrat (EigenstratSnpEntry(..), EigenstratIndEntry(..), 
    readEigenstratInd, GenoEntry(..), GenoLine, Sex(..), 
    readEigenstratSnpStdIn, readEigenstratSnpFile, readEigenstrat, writeEigenstrat) where

import SequenceFormats.Utils (consumeProducer, FormatException(..), Chrom(..))

import Control.Applicative ((<|>))
import Control.Monad (void, forM_)
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.Attoparsec.Text as A
import Data.Char (isSpace)
import Data.Vector (Vector, fromList, toList)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Pipes (Producer, Pipe, (>->), for, cat, yield, Consumer)
import Pipes.Safe (MonadSafe)
import qualified Pipes.Prelude as P
import qualified Pipes.Text.IO as PT
import System.IO (withFile, IOMode(..))
import Turtle (format, w, d, (%), s)

-- |A datatype to represent a single genomic SNP. The constructor arguments are:
-- Chromosome, Position, Reference Allele, Alternative Allele.
data EigenstratSnpEntry = EigenstratSnpEntry Chrom Int Char Char deriving (Eq, Show)

-- |A datatype to represent a single individual. The constructor arguments are:
-- Name, Sex and Population Name
data EigenstratIndEntry = EigenstratIndEntry T.Text Sex T.Text deriving (Show)

-- |A datatype to represent Sex in an Eigenstrat Individual file
data Sex = Male | Female | Unknown deriving (Show)

-- |A datatype to represent the genotype of an individual at a SNP.
data GenoEntry = HomRef | Het | HomAlt | Missing deriving (Eq, Show)

-- |Vector of the genotypes of all individuals at a single SNP.
type GenoLine = Vector GenoEntry

eigenstratSnpParser :: A.Parser EigenstratSnpEntry
eigenstratSnpParser = do
    A.skipMany A.space
    void word
    A.skipMany1 A.space
    chrom <- word
    A.skipMany1 A.space
    void word
    A.skipMany1 A.space
    pos <- A.decimal
    A.skipMany1 A.space
    ref <- A.satisfy (A.inClass "ACTGN")
    A.skipMany1 A.space
    alt <- A.satisfy (A.inClass "ACTGX")
    void A.endOfLine
    return $ EigenstratSnpEntry (Chrom chrom) pos ref alt

word :: A.Parser T.Text
word = A.takeTill isSpace

eigenstratIndParser :: A.Parser EigenstratIndEntry
eigenstratIndParser = do
    A.skipMany A.space
    name <- word
    A.skipMany1 A.space
    sex <- parseSex
    A.skipMany1 A.space
    popName <- word
    void A.endOfLine
    return $ EigenstratIndEntry name sex popName

parseSex :: A.Parser Sex
parseSex = parseMale <|> parseFemale <|> parseUnknown
  where
    parseMale = A.char 'M' >> return Male
    parseFemale = A.char 'F' >> return Female
    parseUnknown = A.char 'U' >> return Unknown

-- |Function to read an Eigenstrat individual file. Returns the Eigenstrat Individual Entries as list.
readEigenstratInd :: (MonadIO m) => FilePath -> m [EigenstratIndEntry]
readEigenstratInd fn = do
    liftIO . withFile fn ReadMode $ \handle -> do
        P.toListM $ consumeProducer eigenstratIndParser (PT.fromHandle handle)

eigenstratGenoParser :: A.Parser GenoLine
eigenstratGenoParser = do
    line <- A.takeWhile1 isValidNum
    void A.endOfLine
    return . fromList $ do
        l <- T.unpack line
        case l of
            '0' -> return HomAlt
            '1' -> return Het
            '2' -> return HomRef
            '9' -> return Missing
            _ -> error "this should never happen"
  where
    isValidNum c = c == '0' || c == '1' || c == '2' || c == '9'

-- |Function to read a Snp File from StdIn. Returns a Pipes-Producer over the EigenstratSnpEntries.
readEigenstratSnpStdIn :: (MonadThrow m, MonadIO m) => Producer EigenstratSnpEntry m ()
readEigenstratSnpStdIn = consumeProducer eigenstratSnpParser PT.stdin

-- |Function to read a Snp File from a file. Returns a Pipes-Producer over the EigenstratSnpEntries.
readEigenstratSnpFile :: (MonadSafe m) => FilePath -> Producer EigenstratSnpEntry m ()
readEigenstratSnpFile = consumeProducer eigenstratSnpParser . PT.readFile

-- |Function to read a full Eigenstrat database from files. Returns a pair of the Eigenstrat Individual Entries, and a joint Producer over the snp entries and the genotypes.
readEigenstrat :: (MonadSafe m) => FilePath -- ^The Genotype file
               -> FilePath -- ^The Snp File
               -> FilePath -- ^The Ind file
               -> m ([EigenstratIndEntry], Producer (EigenstratSnpEntry, GenoLine) m ()) -- The return pair of individual entries and a joint Snp/Geno Producer.
readEigenstrat genoFile snpFile indFile = do
    indEntries <- readEigenstratInd indFile
    let snpProd = readEigenstratSnpFile snpFile
        genoProd = consumeProducer eigenstratGenoParser (PT.readFile genoFile) >-> 
            validateEigenstratEntries (length indEntries)
    return (indEntries, P.zip snpProd genoProd)

validateEigenstratEntries :: (MonadThrow m) => Int -> Pipe GenoLine GenoLine m ()
validateEigenstratEntries nr = for cat $ \line -> do
    if length line /= nr
    then do
        let msg = format ("inconsistent nr of genotypes ("%d%", but should be "%d%") in \
                \genotype line "%w) (length line) nr line
        throwM $ FormatException msg
    else
        yield line

-- |Function to write an Eigenstrat Database. Returns a consumer expecting joint Snp- and Genotype lines.
writeEigenstrat :: (MonadSafe m) => FilePath -- ^The Genotype file
                -> FilePath -- ^The Snp File
                -> FilePath -- ^The Ind file
                -> [EigenstratIndEntry] -- ^The list of individual entries
                -> Consumer (EigenstratSnpEntry, GenoLine) m () -- ^A consumer to read joint Snp/Genotype entries.
writeEigenstrat genoFile snpFile indFile indEntries = do
    liftIO $ writeEigenstratIndFile indFile indEntries
    let snpOutTextConsumer = PT.writeFile snpFile
        genoOutTextConsumer = PT.writeFile genoFile
        toTextPipe = P.map (\(EigenstratSnpEntry chrom pos ref alt, genoLine) ->
            let n = format (s%"_"%d) (unChrom chrom) pos
                snpLine = format (s%"\t"%s%"\t0\t"%d%"\t"%s%"\t"%s%"\n") n (unChrom chrom) pos
                    (T.singleton ref) (T.singleton alt)
                genoLineStr = T.concat . map (format d . toEigenStratNum) . toList $ genoLine
            in  (snpLine, format (s%"\n") genoLineStr))
    toTextPipe >-> P.tee (P.map fst >-> snpOutTextConsumer) >-> P.map snd >-> genoOutTextConsumer
  where
    toEigenStratNum c = case c of
        HomRef -> 2 :: Int
        Het -> 1
        HomAlt -> 0
        Missing -> 9

writeEigenstratIndFile :: (MonadIO m) => FilePath -> [EigenstratIndEntry] -> m ()
writeEigenstratIndFile f indEntries = do
    liftIO . withFile f WriteMode $ \h -> do
        forM_ indEntries $ \(EigenstratIndEntry name sex popName) -> do
            liftIO . T.hPutStrLn h $ format (s%"\t"%s%"\t"%s) name (sexToStr sex) popName
  where
    sexToStr sex = case sex of
        Male -> "M"
        Female -> "F"
        Unknown -> "U"
