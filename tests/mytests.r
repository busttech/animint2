library("testthat")
library("animint2")
library("RSelenium")
library("XML")
source("helper-functions.R")
source("helper-HTML.R")
source("helper-plot-data.r")

tests_init()
tests_run(filter="renderer3-TestWorldBankTwoLayers")
tests_exit()

tests_init("firefox")
tests_run(filter="renderer3-TestWorldBankTwoLayers")
tests_exit()