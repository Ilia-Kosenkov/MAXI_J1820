GetRawFileNames <- function(path, pattern = ".*maxi?18([bvr])([0-9]+).csv") {
    fls <- dir(path, "*.csv", full.names = TRUE)

    fls %>% str_match_all(pattern) %>%
        discard(is_empty) %>%
        map(as.tibble) %>%
        bind_rows #%>%
        #setNames(c("Path", "Band", "ID")) %>%
        #mutate(Band = toupper(Band), ID = as.integer(ID))
}

GetFileSizes <- function(path) {
    data <- path %>% map_int(~read_csv(.x, col_types = cols()) %>%
        nrow())
}

GenerateInputFiles <- function(files, bandInfo = Bands, idPrefix = 600) {
    writeFile <- function(data, path) {
        sink(path)
        seq.int(length.out = nrow(data)) %>%
            map(~sprintf("%s\n1%4d%4d%2d\n",
                data %>% extract(.x, "Path"),
                data %>% extract(.x, "FlSz") %>% as.integer,
                data %>% extract(.x, "ID") %>% as.integer + idPrefix,
                data %>% extract(.x, "BandID") %>% as.integer)) %>%
            map(cat)
        cat("end")
        sink()
    }


    bands <- files %>%
        pull(Band) %>%
        unique

    bands %>%
        map(~filter(files, Band == .x) %>% arrange(ID)) %>%
        setNames(bands) %>%
        map(~writeFile(.x,
            sprintf("%sin.txt", .x %>% extract(1, "Band"))))
}

GatherRawOutput <- function(path) {
    files <- dir(path,
        pattern = "(in\\.txt)|(lpo.\\.txt)|(te.\\.txt)|(.*_.\\.txt)",
        full.names = TRUE,
        ignore.case = TRUE)
    dirPath <- file.path("Output", "RAW")

    if (!dir.exists(dirPath))
        dir.create(dirPath)

    files %>%
        map(~sprintf("unix2dos %s", .x)) %>%
        walk(ExecuteUnix)

    files %>%
        walk(~file.copy(.x, dirPath, overwrite = TRUE))

    files %>%
        walk(file.remove)
}

ApplyCorrections <- function(bandInfo = Bands,
                starFile = file.path("Test", "maxi.sta"),
                filePrefix = "res") {
    bandInfo %>%
        pull(Band) %>%
        map(~sprintf("printf \'%s\\nte%s.txt\\n0\\n0\\n\' | %s && %s",
                starFile,
                .x,
                file.path(".", "Binary", "koko.out"),
                sprintf("mv PRKOKO.txt %s_%s.txt",filePrefix, .x))) %>%
        walk(ExecuteUnix)
}

ProcessFiles <- function(files, method = "polco",
    idPrefix = 600, bandInfo = Bands,
    filePrefix = "res") {
    GenerateInputFiles(files, idPrefix = idPrefix)
    bandInfo %>%
        pull(Band) %>%
        map(~file.path(".", "Binary", sprintf("%s%s.out", method, .x))) %>%
        walk(ExecuteUnix)

    ApplyCorrections(filePrefix = filePrefix)

    GatherRawOutput(".")
}

SplitInTwo <- function(files, date, bandInfo = Bands) {

    bandInfo %>%
        pull(Band) %>%
        map(~filter(files, Band == .x) %>% arrange(ID)) %>%
        setNames(bandInfo %>% pull(Band)) %>%
        map(~pull(.x, Path)) %>%
        map(function(x) map(x, read_csv, col_types = cols())) %>%
        map(bind_rows) %>%
        map(function(x)
            list(Before = filter(x, `T (JD)` <= date),
                 After = filter(x, `T (JD)` > date)))
}

PrepareAvgData <- function(date = 2458222.5) {
    rawFiles <- GetRawFileNames(file.path("Test", "RAW")) %>%
        setNames(c("Path", "Band", "ID")) %>%
        mutate(Band = toupper(Band)) %>%
        mutate(ID = as.integer(ID)) %>%
        mutate(FlSz = GetFileSizes(Path)) %>%
        left_join(Bands, by = "Band", suffix = c("", ".bnd")) %>%
        rename(BandID = ID.bnd)

    dirName <- file.path("Data", "RunTime")

    if (!dir.exists(dirName))
        dir.create(dirName, recursive = TRUE)

    splits <- rawFiles %>% SplitInTwo(date)

    splits %>%
        walk2(Bands %>% pull(Band),
            function(x, b) {
                x %>%
                extract2("Before") %>%
                write_csv(path =
                    file.path(dirName, sprintf("maxi_before_%s.csv", b)))
                x %>%
                extract2("After") %>%
                write_csv(path =
                    file.path(dirName, sprintf("maxi_after_%s.csv", b)))
            })
}

GetAverageFileNames <- function(path = file.path("Data", "RunTime")) {
    files <- dir(file.path("Data", "RunTime"),
        pattern = "maxi_.*_.*\\.csv", full.names = TRUE) %>%
        str_match(".*maxi_(.*)_([BVR])\\.csv") %>% {
            tibble(
                   Path = extract(.,, 1),
                   Band = extract(.,, 3),
                   Type = extract(.,, 2))
        } %>%
        mutate(ID = if_else(Type == "before", 1L, 2L))
}

CombineResults <- function(path = file.path("Output", "RAW"),
                           pattern = "maxi_avg_.\\.txt") {

    data <- dir(path, pattern, full.names = TRUE) %>%
        map(read_lines) %>%
        map(function(x) {
            x %>%
                str_detect(regex("no[[:blank:]]*fil",
                    ignore_case = TRUE)) %>%
            which %>%
            add(1) -> id
            x %>% extract(id:length(x))
        }) %>%
        map(function(x)
            discard(x, ~ str_detect(.x, "^[[:blank:]]$")))

    data %>%
        reduce(c) %>%
        str_split("\ ") %>%
        map(~keep(.x, nzchar)) %>%
        map(as.double) %>%
        map(matrix, nrow = 1) %>%
        map(as.tibble) %>%
        bind_rows %>%
        setNames(c("ID", "FIL", "PX", "PY", "P", "Ep", 
            "A", "Ea", "Nobs", "JD")) %>%
        mutate(ID = as.integer(ID),
               FIL = as.integer(FIL),
               Nobs = as.integer(Nobs)) %>%
        left_join(Bands, by = c("FIL" = "ID")) %>%
        select(-Px, -Py, -Angle) %>%
        mutate(Type = if_else(ID == min(ID), "before", "after")) %>%
        arrange(FIL)

}

GetStats <- function() {
    avgs <- GetAverageFileNames() %>%
        mutate(FlSz = GetFileSizes(Path)) %>%
        left_join(Bands, by = "Band", suffix = c("", ".bnd")) %>%
        rename(BandID = ID.bnd) %>%
        select(-Px, - Py, - Angle) %>%
        arrange(BandID, ID)

    bands <- avgs %>%
        pull(Band) %>%
        unique

    bands %>%
        map(~filter(avgs, Band == .x)) %>%
        map(~arrange(.x, ID)) %>%
        map(function(x) {
            bnd <- x %>% pull(Band) %>% first
            bndInfo <- Bands %>% filter(Band == bnd)
            x %>% pull(Path) %>%
                map(ReadData) %>%
                map(ProcessObservations2, bandInfo = bndInfo) %>%
                map(function(y) {
                    mean <- y %>%
                        extract(1, c("Px", "Py")) %>%
                        as.numeric

                    var <- y %>%
                        extract(1, c("SGx", "SGy")) %>%
                        as.numeric

                    cov <- y %>%
                        extract(1, "Cov") %>%
                        as.numeric

                    n <- y %>%
                        extract(1, "N") %>%
                        as.integer

                    list(mean = mean,
                         sigma = matrix(c(var[1], cov, cov, var[2]), nrow = 2),
                         n = n,
                         band = bnd)
                })

        })
}

if (IsRun()) {
    CompileFortran(file.path("Source", "Fortran"))

    PrepareAvgData()

    avgs <- GetAverageFileNames() %>%
        mutate(FlSz = GetFileSizes(Path)) %>%
        left_join(Bands, by = "Band", suffix = c("", ".bnd")) %>%
        rename(BandID = ID.bnd) %>%
        select(-Px, - Py, - Angle) %>%
        arrange(BandID, ID)

    ProcessFiles(avgs, method = "Lin", idPrefix = 600, filePrefix = "maxi_avg")

    result <- CombineResults()

    result %>% WriteFixed(file.path("Output", "Averages.dat"),
    frmt = c(rep("%5d", 2), rep("%10.4f", 4), rep("%8.2f", 2),
    "%6d", "%16.5f", "%6s", "%8s"))

    GetStats() %>%
        map(function(x) {
            HottellingT2Test(
                    x[[1]]$mean, x[[2]]$mean,
                    x[[1]]$sigma, x[[2]]$sigma,
                    x[[1]]$n, x[[2]]$n) %>%
                mutate(Band = x[[1]]$band)
    }) %>%
    bind_rows %>%
    select(Band, everything()) %>%
    WriteFixed(file.path("Output", "stat_test.dat"),
        frmt = c("%6s", "%12.6f", "%12.6f", rep("%16.6e", 4), rep("%5d", 2)))
   
}