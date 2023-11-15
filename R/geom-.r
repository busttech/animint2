#' @include legend-draw.r
NULL

#' @section Geoms:
#'
#' All \code{geom_*} functions (like \code{geom_point}) return a layer that
#' contains a \code{Geom*} object (like \code{GeomPoint}). The \code{Geom*}
#' object is responsible for rendering the data in the plot.
#'
#' Each of the \code{Geom*} objects is a \code{\link{gganimintproto}} object, descended
#' from the top-level \code{Geom}, and each implements various methods and
#' fields. To create a new type of Geom object, you typically will want to
#' implement one or more of the following:
#'
#' Compared to \code{Stat} and \code{Position}, \code{Geom} is a little
#' different because the execution of the setup and compute functions is
#' split up. \code{setup_data} runs before position adjustments, and
#' \code{draw_layer} is not run until render time,  much later. This
#' means there is no \code{setup_params} because it's hard to communicate
#' the changes.
#'
#' \itemize{
#'   \item Override either \code{draw_panel(self, data, panel_scales, coord)} or
#'     \code{draw_group(self, data, panel_scales, coord)}. \code{draw_panel} is
#'     called once per panel, \code{draw_group} is called once per group.
#'
#'     Use \code{draw_panel} if each row in the data represents a
#'     single element. Use \code{draw_group} if each group represents
#'     an element (e.g. a smooth, a violin).
#'
#'     \code{data} is a data frame of scaled aesthetics. \code{panel_scales}
#'     is a list containing information about the scales in the current
#'     panel. \code{coord} is a coordinate specification. You'll
#'     need to call \code{coord$transform(data, panel_scales)} to work
#'     with non-Cartesian coords. To work with non-linear coordinate systems,
#'     you typically need to convert into a primitive geom (e.g. point, path
#'     or polygon), and then pass on to the corresponding draw method
#'     for munching.
#'
#'     Must return a grob. Use \code{\link{zeroGrob}} if there's nothing to
#'     draw.
#'   \item \code{draw_key}: Renders a single legend key.
#'   \item \code{required_aes}: A character vector of aesthetics needed to
#'     render the geom.
#'   \item \code{default_aes}: A list (generated by \code{\link{aes}()} of
#'     default values for aesthetics.
#'   \item \code{reparameterise}: Converts width and height to xmin and xmax,
#'     and ymin and ymax values. It can potentially set other values as well.
#' }
#' @rdname animint2-gganimintproto
#' @format NULL
#' @usage NULL
#' @export
Geom <- gganimintproto("Geom",
  required_aes = character(),
  non_missing_aes = character(),

  default_aes = aes(),

  draw_key = draw_key_point,

  handle_na = function(self, data, params) {
    remove_missing(data, params$na.rm,
      c(self$required_aes, self$non_missing_aes),
      snake_class(self)
    )
  },

  draw_layer = function(self, data, params, panel, coord) {
    if (empty(data)) {
      n <- if (is.factor(data$PANEL)) nlevels(data$PANEL) else 1L
      return(rep(list(zeroGrob()), n))
    }

    # Trim off extra parameters
    params <- params[intersect(names(params), self$parameters())]

    args <- c(list(quote(data), quote(panel_scales), quote(coord)), params)
    plyr::dlply(data, "PANEL", function(data) {
      if (empty(data)) return(zeroGrob())

      panel_scales <- panel$ranges[[data$PANEL[1]]]
      do.call(self$draw_panel, args)
    }, .drop = FALSE)
  },

  draw_panel = function(self, data, panel_scales, coord, ...) {
    groups <- split(data, factor(data$group))
    grobs <- lapply(groups, function(group) {
      self$draw_group(group, panel_scales, coord, ...)
    })

    ggname(snake_class(self), gTree(
      children = do.call("gList", grobs)
    ))
  },

  draw_group = function(self, data, panel_scales, coord) {
    stop("Not implemented")
  },

  setup_data = function(data, params) data,

  # Combine data with defaults and set aesthetics from parameters
  use_defaults = function(self, data, params = list()) {
    # Fill in missing aesthetics with their defaults
    missing_aes <- setdiff(names(self$default_aes), names(data))
    if (empty(data)) {
      data <- plyr::quickdf(self$default_aes[missing_aes])
    } else {
      data[missing_aes] <- self$default_aes[missing_aes]
    }

    # Override mappings with params
    aes_params <- intersect(self$aesthetics(), names(params))
    check_aesthetics(params[aes_params], nrow(data))
    data[aes_params] <- params[aes_params]
    data
  },

  # Most parameters for the geom are taken automatically from draw_panel() or
  # draw_groups(). However, some additional parameters may be needed
  # for setup_data() or handle_na(). These can not be imputed automatically,
  # so the slightly hacky "extra_params" field is used instead. By
  # default it contains `na.rm`
  extra_params = c("na.rm"),

  parameters = function(self, extra = FALSE) {
    # Look first in draw_panel. If it contains ... then look in draw groups
    panel_args <- names(gganimintproto_formals(self$draw_panel))
    group_args <- names(gganimintproto_formals(self$draw_group))
    args <- if ("..." %in% panel_args) group_args else panel_args

    # Remove arguments of defaults
    args <- setdiff(args, names(gganimintproto_formals(Geom$draw_group)))

    if (extra) {
      args <- union(args, self$extra_params)
    }
    args
  },

  aesthetics = function(self) {
    c(union(self$required_aes, names(self$default_aes)), "group")
  },

  pre_process = function(g, g.data, ranges){
    list(g = g, g.data = g.data)
  },

  ## Save a layer to disk, save and return meta-data.
  ## l- one layer of the ggplot object.
  ## d- one layer of calculated data from ggplot_build(p).
  ## meta- environment of meta-data.
  ## layer_name- name of layer
  ## ggplot- ggplot
  ## built- built list
  ## AnimationInfo- animation list
  ## ID- number starting from 1
  ## returns- list representing a layer, with corresponding aesthetics, ranges, and groups.
  export_animint = function(l, d, meta, layer_name, ggplot, built, AnimationInfo) {
    xminv <- y <- xmaxv <- chunks.for <- NULL
    ## above to avoid NOTE on CRAN check.
    g <- list(geom=strsplit(layer_name, "_")[[1]][2])
    g$classed <- layer_name

    ranges <- built$panel$ranges

    ## needed for when group, etc. is an expression:
    g$aes <- sapply(l$mapping, function(k) as.character(as.expression(k)))

    ## use un-named parameters so that they will not be exported
    ## to JSON as a named object, since that causes problems with
    ## e.g. colour.
    ## 'colour', 'size' etc. have been moved to aes_params
    g$params <- getLayerParams(l)

    ## Make a list of variables to use for subsetting. subset_order is the
    ## order in which these variables will be accessed in the recursive
    ## JavaScript array structure.

    ## subset_order IS in fact useful with geom_segment! For example, in
    ## the first plot in the breakpointError example, the geom_segment has
    ## the following exported data in plot.json

    ## "subset_order": [
    ##  "showSelected",
    ## "showSelected2"
    ## ],

    ## This information is used to parse the recursive array data structure
    ## that allows efficient lookup of subsets of data in JavaScript. Look at
    ## the Firebug DOM browser on
    ## http://sugiyama-www.cs.titech.ac.jp/~toby/animint/breakpoints/index.html
    ## and navigate to plot.Geoms.geom3.data. You will see that this is a
    ## recursive array that can be accessed via
    ## data[segments][bases.per.probe] which is an un-named array
    ## e.g. [{row1},{row2},...] which will be bound to the <line> elements by
    ## D3. The key point is that the subset_order array stores the order of the
    ## indices that will be used to select the current subset of data (in
    ## this case showSelected=segments, showSelected2=bases.per.probe). The
    ## currently selected values of these variables are stored in
    ## plot.Selectors.

    ## Separate .variable/.value selectors
    s.aes <- selectSSandCS(g$aes)
    meta$selector.aes[[g$classed]] <- s.aes

    ## Do not copy group unless it is specified in aes, and do not copy
    ## showSelected variables which are specified multiple times.
    do.not.copy <- colsNotToCopy(g, s.aes)
    copy.cols <- ! names(d) %in% do.not.copy

    g.data <- d[copy.cols]

    is.ss <- names(g$aes) %in% s.aes$showSelected$one
    show.vars <- g$aes[is.ss]
    pre.subset.order <- as.list(names(show.vars))

    is.cs <- names(g$aes) %in% s.aes$clickSelects$one
    update.vars <- g$aes[is.ss | is.cs]

    update.var.names <- if(0 < length(update.vars)){
      data.frame(variable=names(update.vars), value=NA)
    }

    interactive.aes <- with(s.aes, {
      rbind(clickSelects$several, showSelected$several,
            update.var.names)
    })

    ## Construct the selector.
    for(row.i in seq_along(interactive.aes$variable)){
      aes.row <- interactive.aes[row.i, ]
      is.variable.value <- !is.na(aes.row$value)
      selector.df <- if(is.variable.value){
        selector.vec <- g.data[[paste(aes.row$variable)]]
        data.frame(value.col=aes.row$value,
                  selector.name=unique(paste(selector.vec)))
      }else{
        value.col <- paste(aes.row$variable)
        data.frame(value.col,
                  selector.name=update.vars[[value.col]])
      }
      for(sel.i in 1:nrow(selector.df)){
        sel.row <- selector.df[sel.i,]
        value.col <- paste(sel.row$value.col)
        selector.name <- paste(sel.row$selector.name)
        ## If this selector was defined by .variable .value aes, then we
        ## will not generate selectize widgets.
        meta$selectors[[selector.name]]$is.variable.value <- is.variable.value
        ## If this selector has no defined type yet, we define it once
        ## and for all here, so we can use it later for chunk
        ## separation.
        if(is.null(meta$selectors[[selector.name]]$type)){
          selector.type <- meta$selector.types[[selector.name]]
          if(is.null(selector.type))selector.type <- "single"
          stopifnot(is.character(selector.type))
          stopifnot(length(selector.type)==1)
          stopifnot(selector.type %in% c("single", "multiple"))
          meta$selectors[[selector.name]]$type <- selector.type
        }
        ## If this selector does not have any clickSelects then we show
        ## the selectize widgets by default.
        for(look.for in c("showSelected", "clickSelects")){
          if(grepl(look.for, aes.row$variable)){
            meta$selectors[[selector.name]][[look.for]] <- TRUE
          }
        }
        ## We also store all the values of this selector in this layer,
        ## so we can accurately set levels after all geoms have been
        ## compiled.
        value.vec <- unique(g.data[[value.col]])
        key <- paste(g$classed, row.i, sel.i)
        meta$selector.values[[selector.name]][[key]] <-
          list(values=paste(value.vec), update=g$classed)
      }
    }

    is.show <- grepl("showSelected", names(g$aes))
    has.show <- any(is.show)
    ## Error if non-identity stat is used with showSelected, since
    ## typically the stats will delete the showSelected column from the
    ## built data set. For example geom_bar + stat_bin doesn't make
    ## sense with clickSelects/showSelected, since two
    ## clickSelects/showSelected values may show up in the same bin.
    stat.type <- class(l$stat)[[1]]
    checkForNonIdentityAndSS(stat.type, has.show, is.show, l,
                            g$classed, names(g.data), names(g$aes))

    ## Warn if non-identity position is used with animint aes.
    position.type <- class(l$position)[[1]]
    if(has.show && position.type != "PositionIdentity"){
      print(l)
      warning("showSelected only works with position=identity, problem: ",
              g$classed)
    }

    ##print("before pre-processing")

    ## Pre-process some complex geoms so that they are treated as
    ## special cases of basic geoms. In ggplot2, this processing is done
    ## in the draw method of the geoms.

    processed_values <- l$geom$pre_process(g, g.data, ranges)
    g <- processed_values$g
    g.data <- processed_values$g.data
    ## Check g.data for color/fill - convert to hexadecimal so JS can parse correctly.
    for(color.var in c("colour", "color", "fill", "colour_off", "color_off", "fill_off")){
      if(color.var %in% names(g.data)){
        g.data[,color.var] <- toRGB(g.data[,color.var])
      }
      if(color.var %in% names(g$params)){
        g$params[[color.var]] <- toRGB(g$params[[color.var]])
      }
    }

    has.no.fill <- g$geom %in% c("path", "line")
    zero.size <- any(g.data$size == 0, na.rm=TRUE)
    if(zero.size && has.no.fill){
      warning(sprintf("geom_%s with size=0 will be invisible",g$geom))
    }

    ## raise warning for using *_off params without clickSelects
    has.off <- any(names(g$params) %like% "_off")
    has.no.cs <- !any(is.cs)
    if(has.no.cs && has.off){
      off.vec <- grep( "_off$", names(g$params), value = TRUE)
      warning(sprintf("%s has %s which is not used because this geom has no clickSelects; please specify clickSelects or remove %s",
      g$classed, paste(off.vec, collapse=", "), paste(off.vec, collapse=", ")))
    }

    ## raise warning for geoms does not support fill
    has.fill.off <- any(names(g$params) == "fill_off")
    no.fill.geom <- c("path", "line", "segment", "linerange", "hline", "vline")
    if (g$geom %in% no.fill.geom && has.fill.off) {
      g$params <- g$params[!names(g$params) %in% "fill_off"]
      warning(sprintf("%s has fill_off which is not supported.", g$classed))
    }
    ## TODO: coord_transform maybe won't work for
    ## geom_dotplot|rect|segment and polar/log transformations, which
    ## could result in something nonlinear. For the time being it is
    ## best to just ignore this, but you can look at the source of
    ## e.g. geom-rect.r in ggplot2 to see how they deal with this by
    ## doing a piecewise linear interpolation of the shape.

    ## Flip axes in case of coord_flip
    if(inherits(ggplot$coordinates, "CoordFlip")){
      names(g.data) <- switch_axes(names(g.data))
    }

    ## Output types
    ## Check to see if character type is d3's rgb type.
    g$types <- sapply(g.data, function(x) {
      type <- paste(class(x), collapse="-")
      if(type == "character"){
        if(sum(!is.rgb(x))==0){
          "rgb"
        }else if(sum(!is.linetype(x))==0){
          "linetype"
        }else {
          "character"
        }
      }else{
        type
      }
    })
    g$types[["group"]] <- "character"

    ## convert ordered factors to unordered factors so javascript
    ## doesn't flip out.
    ordfactidx <- which(g$types=="ordered-factor")
    for(i in ordfactidx){
      g.data[[i]] <- factor(as.character(g.data[[i]]))
      g$types[[i]] <- "factor"
    }

    ## Get unique values of time variable.
    time.col <- NULL
    if(is.list(AnimationInfo$time)){ # if this is an animation,
      g.time.list <- list()
      for(c.or.s in names(s.aes)){
        cs.info <- s.aes[[c.or.s]]
        for(a in cs.info$one){
          if(g$aes[[a]] == AnimationInfo$time$var){
            g.time.list[[a]] <- g.data[[a]]
            time.col <- a
          }
        }
        for(row.i in seq_along(cs.info$several$value)){
          cs.row <- cs.info$several[row.i,]
          c.name <- paste(cs.row$variable)
          is.time <- g.data[[c.name]] == AnimationInfo$time$var
          g.time.list[[c.name]] <- g.data[is.time, paste(cs.row$value)]
        }
      }
      u.vals <- unique(unlist(g.time.list))
      if(length(u.vals)){
        AnimationInfo$timeValues[[paste(g$classed)]] <- sort(u.vals)
      }
    }
    ## Make the time variable the first subset_order variable.
    if(length(time.col)){
      pre.subset.order <- pre.subset.order[order(pre.subset.order != time.col)]
    }

    ## Determine which showSelected values to use for breaking the data
    ## into chunks. This is a list of variables which have the same
    ## names as the selectors. E.g. if chunk_order=list("year") then
    ## when year is clicked, we may need to download some new data for
    ## this geom.
    subset.vec <- unlist(pre.subset.order)
    if("chunk_vars" %in% names(g$params)){ #designer-specified chunk vars.
      designer.chunks <- g$params$chunk_vars
      if(!is.character(designer.chunks)){
        stop("chunk_vars must be a character vector; ",
            "use chunk_vars=character() to specify 1 chunk")
      }
      not.subset <- !designer.chunks %in% g$aes[subset.vec]
      if(any(not.subset)){
        stop("invalid chunk_vars ",
            paste(designer.chunks[not.subset], collapse=" "),
            "; possible showSelected variables: ",
            paste(g$aes[subset.vec], collapse=" "))
      }
      is.chunk <- g$aes[subset.vec] %in% designer.chunks
      chunk.cols <- subset.vec[is.chunk]
      nest.cols <- subset.vec[!is.chunk]
    }else{ #infer a default, either 0 or 1 chunk vars:
      if(length(meta$selectors)==0){
        ## no selectors, just make 1 chunk.
        nest.cols <- subset.vec
        chunk.cols <- NULL
      }else{
        selector.types <- sapply(meta$selectors, "[[", "type")
        selector.names <- g$aes[subset.vec]
        subset.types <- selector.types[selector.names]
        can.chunk <- subset.types != "multiple"
        names(can.chunk) <- subset.vec
        ## Guess how big the chunk files will be, and reduce the number of
        ## chunks if there are any that are too small.
        tmp <- tempfile()
        some.lines <- rbind(head(g.data), tail(g.data))
        write.table(some.lines, tmp,
                    col.names=FALSE,
                    quote=FALSE, row.names=FALSE, sep="\t")
        bytes <- file.info(tmp)$size
        bytes.per.line <- bytes/nrow(some.lines)
        bad.chunk <- function(){
          if(all(!can.chunk))return(NULL)
          can.chunk.cols <- subset.vec[can.chunk]
          maybe.factors <- g.data[, can.chunk.cols, drop=FALSE]
          for(N in names(maybe.factors)){
            maybe.factors[[N]] <- paste(maybe.factors[[N]])
          }
          rows.per.chunk <- table(maybe.factors)
          bytes.per.chunk <- rows.per.chunk * bytes.per.line
          if(all(4096 < bytes.per.chunk))return(NULL)
          ## If all of the tsv chunk files are greater than 4KB, then we
          ## return NULL here to indicate that the current chunk
          ## variables (indicated in can.chunk) are fine.

          ## In other words, the compiler will not break a geom into
          ## chunks if any of the resulting chunk tsv files is estimated
          ## to be less than 4KB (of course, if the layer has very few
          ## data overall, the compiler creates 1 file which may be less
          ## than 4KB, but that is fine).
          dim.byte.list <- list()
          if(length(can.chunk.cols) == 1){
            dim.byte.list[[can.chunk.cols]] <- sum(bytes.per.chunk)
          }else{
            for(dim.i in seq_along(can.chunk.cols)){
              dim.name <- can.chunk.cols[[dim.i]]
              dim.byte.list[[dim.name]] <-
                apply(bytes.per.chunk, -dim.i, sum)
            }
          }
          selector.df <-
            data.frame(chunks.for=length(rows.per.chunk),
                      chunks.without=sapply(dim.byte.list, length),
                      min.bytes=sapply(dim.byte.list, min))
          ## chunks.for is the number of chunks you get if you split the
          ## data set using just this column. If it is 1, then it is
          ## fine to chunk on this variable (since we certainly won't
          ## make more than 1 small tsv file) and in fact we want to
          ## chunk on this variable, since then this layer's data won't
          ## be downloaded at first if it is not needed.
          not.one <- subset(selector.df, 1 < chunks.for)
          if(nrow(not.one) == 0){
            NULL
          }else{
            rownames(not.one)[[which.max(not.one$min.bytes)]]
          }
        }
        while({
          bad <- bad.chunk()
          !is.null(bad)
        }){
          can.chunk[[bad]] <- FALSE
        }
        if(any(can.chunk)){
          nest.cols <- subset.vec[!can.chunk]
          chunk.cols <- subset.vec[can.chunk]
        }else{
          nest.cols <- subset.vec
          chunk.cols <- NULL
        }
      } # meta$selectors > 0
    }

    # If there is only one PANEL, we don't need it anymore.
    # g$PANEL <- unique(g.data[["PANEL"]])
    plot.has.panels <- nrow(built$panel$layout) > 1
    g.data <- removeUniquePanelValue(g.data, plot.has.panels)

    ## Also add pointers to these chunks from the related selectors.
    if(length(chunk.cols)){
      selector.names <- as.character(g$aes[chunk.cols])
      chunk.name <- paste(selector.names, collapse="_")
      g$chunk_order <- as.list(selector.names)
      for(selector.name in selector.names){
        meta$selectors[[selector.name]]$chunks <-
          unique(c(meta$selectors[[selector.name]]$chunks, chunk.name))
      }
    }else{
      g$chunk_order <- list()
    }
    g$nest_order <- as.list(nest.cols)
    names(g$chunk_order) <- NULL
    names(g$nest_order) <- NULL
    g$subset_order <- g$nest_order

    ## If this plot has more than one PANEL then add it to subset_order
    ## and nest_order.
    if(plot.has.panels){
      g$subset_order <- c(g$subset_order, "PANEL")
      g$nest_order <- c(g$nest_order, "PANEL")
    }

    ## nest_order should contain both .variable .value aesthetics, but
    ## subset_order should contain only .variable.
    if((nrow(s.aes$showSelected$several) > 0)){
      g$nest_order <- with(s.aes$showSelected$several, {
        c(g$nest_order, paste(variable), paste(value))
      })
      g$subset_order <-
        c(g$subset_order, paste(s.aes$showSelected$several$variable))
    }

    ## group should be the last thing in nest_order, if it is present.
    data.object.geoms <- c("line", "path", "ribbon", "polygon")
    if("group" %in% names(g$aes) && g$geom %in% data.object.geoms){
      g$nest_order <- c(g$nest_order, "group")
    }

    ## Some geoms should be split into separate groups if there are NAs.
    if(any(is.na(g.data)) && "group" %in% names(g$aes)){
      sp.cols <- unlist(c(chunk.cols, g$nest_order))
      order.args <- list()
      for(sp.col in sp.cols){
        order.args[[sp.col]] <- g.data[[sp.col]]
      }
      ord <- do.call(order, order.args)
      g.data <- g.data[ord,]
      is.missing <- apply(is.na(g.data), 1, any)
      diff.vec <- diff(is.missing)
      new.group.vec <- c(FALSE, diff.vec == 1)
      for(chunk.col in sp.cols){
        one.col <- g.data[[chunk.col]]
        is.diff <- c(FALSE, one.col[-1] != one.col[-length(one.col)])
        new.group.vec[is.diff] <- TRUE
      }
      subgroup.vec <- cumsum(new.group.vec)
      g.data$group <- subgroup.vec
    }

    ## Find infinite values and replace with range min/max.
    for(xy in c("x", "y")){
      range.name <- paste0(xy, ".range")
      range.mat <- sapply(ranges, "[[", range.name)
      xy.col.vec <- grep(paste0("^", xy), names(g.data), value=TRUE)
      xy.col.df <- g.data[, xy.col.vec, drop=FALSE]
      cmp.list <- list(`<`, `>`)#order is important here!
      for(row.i in seq_along(cmp.list)){
        ## PANEL may be a factor so it is not good enough to do
        ## if(is.numeric(g.data$PANEL))
        panel.vec <- if("PANEL" %in% names(g.data)){
          g.data$PANEL
        }else{
          rep(1, nrow(g.data))
        }
        extreme.vec <- range.mat[row.i, panel.vec]
        cmp <- cmp.list[[row.i]]
        to.rep <- cmp(xy.col.df, extreme.vec)
        row.vec <- row(to.rep)[to.rep]
        xy.col.df[to.rep] <- extreme.vec[row.vec]
      }
      g.data[, xy.col.vec] <- xy.col.df
    }

    ## Determine if there are any "common" data that can be saved
    ## separately to reduce disk usage.
    data.or.null <- getCommonChunk(g.data, chunk.cols, g$aes)
    g.data.varied <- if(is.null(data.or.null)){
      split_recursive(na.omit(g.data), chunk.cols)
    }else{
      g$columns$common <- as.list(names(data.or.null$common))
      tsv.name <- sprintf("%s_chunk_common.tsv", g$classed)
      tsv.path <- file.path(meta$out.dir, tsv.name)
      write.table(data.or.null$common, tsv.path,
                  quote = FALSE, row.names = FALSE,
                  sep = "\t")
      data.or.null$varied
    }

    list(g=g, g.data.varied=g.data.varied, timeValues=AnimationInfo$timeValues)
  }
)


#' Graphical units
#'
#' Multiply size in mm by these constants in order to convert to the units
#' that grid uses internally for \code{lwd} and \code{fontsize}.
#'
#' @name graphical-units
NULL

#' @export
#' @rdname graphical-units
.pt <- 72.27 / 25.4
#' @export
#' @rdname graphical-units
.stroke <- 96 / 25.4

check_aesthetics <- function(x, n) {
  ns <- vapply(x, length, numeric(1))
  good <- ns == 1L | ns == n

  if (all(good)) {
    return()
  }

  stop(
    "Aesthetics must be either length 1 or the same as the data (", n, "): ",
    paste(names(!good), collapse = ", "),
    call. = FALSE
  )
}
