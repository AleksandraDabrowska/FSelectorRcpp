utils::globalVariables("it")

#' @noRd
exhaustive_search <- function(attributes, fun, data,
                              sizes = 1:length(attributes),
                              parallel = TRUE, ...) {

  len <- length(attributes)
  fun <- match.fun(fun)
  zeroes <- rep(0, len)
  childComb <- NULL

  for (size in sizes) {
    childComb <- cbind(childComb,
                       apply(combn(1:len, size), 2, function(i) {
                         x <- zeroes
                         x[i] <- 1
                         x
                       }))
  }

  matIter <- iter(childComb, by = "column")

  if (parallel && getDoParRegistered()) {
    `%op%` <- `%dopar%`
    if (getDoParName() == "doSNOW") {
      tpb <- txtProgressBar(max = matIter$length, style = 3)
      progress <- function(n) {
        setTxtProgressBar(pb = tpb, value = n)
      }
      opts <- list(progress = progress)
    } else {
      opts <- NULL
    }
  } else {
    `%op%` <- `%do%`
    opts <- NULL
  }

  result <- foreach(it = matIter, .options.snow = opts, ...) %op% {
    fun(attributes[as.logical(as.numeric(it))], data)
  }

  maxIdx <- which.max(result)
  allResults <- setNames(as.data.frame(t(rbind(childComb, result))),
                         c(attributes, "values"))
  bestResult <- allResults[maxIdx, ]
  res <- list(best = bestResult,
              all = allResults,
              fun = fun)

  return(res)
}

#' @noRd
greedy_search <- function(attributes, fun, data,
                          type = c("forward", "backward"),
                          parallel = TRUE, ...) {

  len <- length(attributes)
  fun <- match.fun(fun)
  type <- match.arg(type)
  isForward <- type == "forward"
  best <- list(result = -Inf, attrs = rep(as.numeric(!isForward), len))

  if (!isForward) {
    best$result <- fun(attributes[as.logical(best$attrs)], data)
  }

  allResults <- NULL

  repeat {
    children <- get_children(best$attrs, type)
    if (is.null(children)) {
      break
    }

    iterChild <- iter(children, by = "row")

    if (parallel && getDoParRegistered()) {
      `%op%` <- `%dopar%`
      if (getDoParName() == "doSNOW") {
        tpb <- txtProgressBar(max = iterChild$length, style = 3)
        progress <- function(n) {
          setTxtProgressBar(pb = tpb, value = n)
        }
        opts <- list(progress = progress)
      } else {
        opts <- NULL
      }
    } else {
      `%op%` <- `%do%`
      opts <- NULL
    }

    childrenResults <- foreach(it = iterChild, .options.snow = opts, ...) %op% {
      fun(attributes[as.logical(as.numeric(it))], data)
    }

    maxIdx <- which.max(childrenResults)

    if (childrenResults[[maxIdx]] > best$result) {
      best$result <- childrenResults[[maxIdx]]
      best$attrs <- children[maxIdx, ]
      allResults <- rbind(allResults, c(best$attrs, best$result))
    } else {
      break
    }
  }

  allResults <- setNames(as.data.frame(allResults),
                         c(attributes, "values"))
  bestResult <- tail(allResults, 1)
  res <- list(best = bestResult,
              all = allResults,
              fun = fun)

  return(res)
}

#' General Feature Searching Engine
#'
#' A convenience wrapper for \code{greedy} and \code{exhaustive} feature selection algorithms that
#' extract valuable attributes depending on the evaluation method (called evaluator).
#'
#' @param attributes A character vector with attributes' names to be used to extract the most valuable features.
#' @param fun A function (evaluator) to be used to score features' sets at each iteration of the algorithm passed via \code{mode}.
#' See Examples.
#' @param data A data set for \code{fun} function (evaluator).
#' @param mode A character that determines which search algorithm to perform. Defualt is \code{"greedy"}.
#' @param type Used when \code{mode = "greedy"} - whether to use the
#' \code{backward} or the \code{forward} multiple-way search. Default is \code{"forward"}.
#' @param sizes Used when \code{mode = "exhaustive"} - a vector of sizes
#' of attributes subsets.
#' @param parallel Allow parallelization.
#' @param \dots Other arguments passed to \link{foreach} function.
#'
#' @author Zygmunt Zawadzki \email{zygmunt.zawadzki@@gmail.com}
#' @author Krzysztof Slomczynski \email{krzysztofslomczynski@@gmail.com}
#'
#' @importFrom foreach foreach %dopar% %do% getDoParRegistered getDoParName
#' @importFrom iterators iter
#' @importFrom stats setNames
#' @importFrom utils setTxtProgressBar txtProgressBar tail
#'
#' @details The evaluator function passed with \code{fun} is used to determine
#' the importance score of current features' subset.
#' The score is used in a multiple-way (backward or forward) \code{greedy}
#' algorithm as a stopping moment or as a selection criterion
#' in the \code{exhaustive} search that checks all possible
#' attributes' subset combinations (of sizes passed in \code{sizes}).
#'
#' @return A list with following components
#' \itemize{
#'   \item best - a \link{data.frame} with the best subset and it's score (1 - feature used, 0 - feature not used),
#'   \item all - a \link{data.frame} with all checked features' subsets and their score (1 - feature used, 0 - feature not used),
#'   \item data - the data used in the feature selection,
#'   \item fun - the evaluator used to compute the score of importance for features' subsets,
#'   \item call - an origin call of the \code{feature_search},
#'   \item mode - the mode used in the call.
#' }
#'
#' @note Note that score depends on the evaluator you provide in the \code{fun} parameter.
#'
#' @examples
#'
#' # Enable parallelization in examples
#'  library(doSNOW) # doSNOW has an option for progress bar
#'  cl <- makeCluster(2)
#'  registerDoSNOW(cl)
#'
#' # Close at the end
#' # stopCluster(cl)
#' # registerDoSEQ()
#'
#' # 1) Evaluator from FSelector package.
#' evaluator <- function(subset, data, dependent = names(iris)[5]) {
#'   library(rpart)
#'   k <- 5
#'   splits <- runif(nrow(data))
#'   results <- sapply(1:k, function(i) {
#'     test.idx <- (splits >= (i - 1) / k) & (splits < i / k)
#'     train.idx <- !test.idx
#'     test <- data[test.idx, , drop = FALSE]
#'     train <- data[train.idx, , drop = FALSE]
#'     tree <- rpart(to_formula(subset, dependent), train)
#'     error.rate <- sum(test[[dependent]] != predict(tree, test, type = "c")) /
#'     nrow(test)
#'     return(1 - error.rate)
#'   })
#'   return(mean(results))
#' }
#'
#' # Default greedy search.
#' system.time(
#'   feature_search(attributes = names(iris)[-5],
#'                  fun = evaluator,
#'                  data = iris)
#' )
#' system.time(
#'   feature_search(attributes = names(iris)[-5],
#'                  fun = evaluator,
#'                  data = iris,
#'                  parallel = FALSE)
#' )
#'
#' # Optional exhaustive search.
#' system.time(
#'   feature_search(attributes = names(iris)[-5],
#'                  fun = evaluator,
#'                  data = iris,
#'                  mode = "exhaustive")
#' )
#' system.time(
#'   feature_search(attributes = names(iris)[-5],
#'                  fun = evaluator,
#'                  data = iris,
#'                  mode = "exhaustive",
#'                  parallel = FALSE)
#' )
#'
#' # 2) Maximize R^2 statistics in the linear regression model/problem.
#'
#' evaluator_R2_lm <- function(attributes, data, dependent = names(iris)[1]) {
#'   summary(
#'     lm(to_formula(attributes, dependent), data = data)
#'   )$r.squared
#' }
#'
#' feature_search(attributes = names(iris)[-1],
#'                fun = evaluator_R2_lm, data = iris,
#'                mode = "exhaustive")
#'
#' # 3) Optimize BIC crietion in generalized linear model.
#' # Aim of Bayesian approach it to identify the model with the highest
#' # probability of being the true model. - Kuha 2004
#'
#' utils::data(anorexia, package = "MASS")
#'
#' evaluator_BIC_glm <- function(attributes, data, dependent = "Postwt") {
#'   extractAIC(
#'     fit = glm(to_formula(attributes, dependent), family = gaussian,
#'               data = data),
#'     k = log(nrow(data))
#'   )[2]
#' }
#'
#' feature_search(attributes = c("Prewt", "Treat", "offset(Prewt)"),
#'                fun = evaluator_BIC_glm,
#'                data = anorexia,
#'                mode = "exhaustive")
#'
#' # Close parallelization
#' stopCluster(cl)
#' registerDoSEQ()
#'
#' @export
feature_search <- function(attributes, fun, data,
                           mode = c("greedy", "exhaustive"),
                           type = c("forward", "backward"),
                           sizes = 1:length(attributes), parallel = TRUE,
                           ...) {

  call <- match.call()
  mode <- match.arg(mode)
  if (mode == "greedy") {
    type <- match.arg(type)
    output <- greedy_search(attributes = attributes, fun = fun, data = data,
                            type = type, parallel = parallel, ...)
  } else if (mode == "exhaustive") {
    output <- exhaustive_search(attributes = attributes, fun = fun, data = data,
                                sizes = sizes,
                                parallel = parallel, ...)
  }

  output <- c(output, call = call, mode = mode, data = data)

  return(output)
}
