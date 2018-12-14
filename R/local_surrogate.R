single_column_surrogate <- function(x, new_observation, size, seed = NULL,
                                    sampling = "uniform") {
  feature_representations <- lapply(
    colnames(new_observation),
    function(colname) {
      feature_representation(x,
                             new_observation,
                             colname)
    }
  )

  encoded_data <- as.data.frame(feature_representations)
  colnames(encoded_data) <- colnames(new_observation)

  p <- ncol(encoded_data)
  simulated_data <- as.data.frame(lapply(encoded_data,
                                         function(column) {
                                           as.character(rep(levels(column)[2], size))
                                         }), stringsAsFactors = FALSE)

  probs <- lapply(encoded_data,
                  function(column) {
                    as.data.frame(prop.table(table(column)))$Freq
                  })

  if(!is.null(set.seed)) set.seed(seed)
  for(row_number in 1:size) {
    n_changes <- sample(1:p, 1)
    change_indices <- sample(1:p, n_changes)
    if(sampling == "uniform") {
      simulated_data[row_number, change_indices] <- "baseline"
    } else {
      for(index in change_indices) {
        simulated_data[row_number, index] <- sample(
          levels(encoded_data[, index]),
          1,
          prob = probs[[index]])
      }
    }
  }

  for(col_number in 1:p) {
    simulated_data[, col_number] <- factor(
      simulated_data[, col_number],
      levels = levels(encoded_data[, col_number])
    )
  }

  n_rows <- nrow(encoded_data)
  to_predict <- data.frame(lapply(colnames(simulated_data),
                                  function(column) {
                                    how_many_baselines <- sum(simulated_data[, column] == "baseline")
                                    baseline_indices <- which(encoded_data[, column] == "baseline")
                                    if(is.numeric(explainer$data[, column])) {
                                      ifelse(simulated_data[, column] == "baseline",
                                             sample(explainer$data[baseline_indices, column],
                                                    how_many_baselines),
                                             rep(new_observation[, column], size - how_many_baselines)
                                      )
                                    } else {
                                      ifelse(simulated_data[, column] == "baseline",
                                             as.character(sample(explainer$data[baseline_indices, column],
                                                                 how_many_baselines)),
                                             as.character(rep(new_observation[, column],
                                                              size - how_many_baselines))
                                      )

                                    }
                                    # sample(explainer$data[setdiff(1:n_rows, baseline_indices), column],
                                    # size - how_many_baselines) # tak tez mozna losowac
                                  }))
  colnames(to_predict) <- colnames(simulated_data)
  for(i in 1:p) {
    if(is.numeric(x$data[, i])) {
      to_predict[, i] <- as.numeric(to_predict[, i])
    } else {
      to_predict[, i] <- factor(to_predict[, i],
                                levels = levels(x$data[, i]))
    }
    class(to_predict[, i]) <- class(x$data[, i])
  }
  predicted_scores <- x$predict_function(x$model, to_predict)
  simulated_data[["y"]] <- 1
  fitted_model <- glmnet::cv.glmnet(model.matrix(y ~., data =  simulated_data)[, -1],
                                    predicted_scores,
                                    alpha = 1)
  result <- as.data.frame(as.matrix(coef(fitted_model, lambda = "lambda.min")))
  result$variable <- rownames(result)
  rownames(result) <- NULL
  colnames(result)[1] <- "estimated"
  for(row_number in 2:nrow(result)) {
    result[row_number, "variable"] <- stringr::str_sub(result[row_number, "variable"],
                                                       stringr::str_length(colnames(new_observation)[row_number - 1]) + 1)

  }
  result
}


#' LIME-like explanations based on Ceteris Paribus curves
#'
#' @param x an explainer created with function DALEX2::explain().
#' @param new_observation an observation to be explained. Columns in should correspond to columns in the data argument to x.
#' @param size number of similar observation to be sampled.
#' @param seed If not NULL, seed will be set to this value for reproducibility.
#' @param sampling Parameter that controls sampling while creating new observations.
#'
#' @return data.frame of class local_surrogate_explainer
#'
#' @export
#'

individual_surrogate_model <- function(x, new_observation, size, seed = NULL,
                                       sampling = "uniform") {
  try_predict <- x$predict_function(x$model, x$data[1:5, ])
  if(is.factor(x$y) | (!is.null(ncol(try_predict)))) {
    explainer <- lapply(unique(colnames(try_predict)), function(unique_level) {
      internal_explainer <- x
      internal_explainer$predict_function <- function(model, newdata) {
        x$predict_function(model, newdata)[, unique_level]

      }
      result <- single_column_surrogate(internal_explainer, new_observation,
                                        size, seed, sampling)
      result[, "response"] <- unique_level
      result[, "predicted_value"] <- internal_explainer$predict_function(
        internal_explainer$model,
        new_observation
      )
      result
    })
  } else {
    if(is.numeric(x$y) | is.null(ncol(try_predict))) {
      explainer <- single_column_surrogate(
        x, new_observation,
        size, seed, sampling
      )
      explainer[["response"]] <- ""
      explainer[["predicted_value"]] <- x$predict_function(
        x$model,
        new_observation
      )
    } else {
      stop("Response must be numeric or factor vector")
    }
  }
  if(is.factor(x$y) | (!is.null(ncol(try_predict)))) {
    explainer <- do.call("rbind", explainer)
  }
  class(explainer) <- c("local_surrogate_explainer", class(explainer))
  attr(explainer, "new_observation") <- new_observation
  explainer
}


#' @import ggplot2
#' @importFrom stats reorder
#' @export

plot.local_surrogate_explainer <- function(x, ...) {
  variable <- estimated <- NULL

  x$response <- paste(
    x$response,
    "predicted value: ",
    x$predicted_value
  )

  x$estimated <- unlist(tapply(x$estimated,
                               x$response,
                               function(y) {
                                 c(y[1], y[-1] + y[1])
                               }), use.names = FALSE)
  x$intercept = unlist(
    tapply(
      x$estimated,
      x$response,
      function(y) rep(y[1], length(y))
    )
  )

  x <- x[x$variable != "(Intercept)", ]

  ggplot(x, aes(x = reorder(variable, -abs(estimated)),
                y = estimated)) +
    theme_bw() +
    geom_hline(aes(yintercept = intercept),
               size = 1)  +
    geom_pointrange(aes(ymin = intercept, ymax = estimated)) +
    facet_wrap(~response, ncol = 1, scales = "free_y") +
    coord_flip() +
    ylab("Estimated effect") +
    xlab("Variable / level")
}