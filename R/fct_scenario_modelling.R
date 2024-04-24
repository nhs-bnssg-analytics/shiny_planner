#' scenario_modelling
#'
#' @description A fct function
#'
#' @return The return value, if any, from executing the function.
#' @param scenario_data tibble; input data for the scenario being modelled -
#'   data comes from the table editting interface
#' @param ics_code character(1); three letter ICS code (beginning with Q)
#' @param model named list of model workflow objects whose names are the
#'   performance metrics
#' @importFrom tidyr pivot_wider pivot_longer complete
#' @importFrom dplyr select bind_cols mutate left_join setdiff bind_rows filter
#' @importFrom parsnip predict.model_fit
#' @importFrom purrr lmap
#' @importFrom rlang sym
#' @import recipes
#' @import glmnet
#' @noRd
model_scenario_data <- function(scenario_data, ics_code, model) {

  performance_data <- ics_data(
    ics_code = ics_code,
    domain_type = "Performance"
  ) |>
    select(
      "org",
      "year",
      "metric",
      "value"
    ) |>
    tidyr::pivot_wider(
      names_from = !!sym("metric"),
      values_from = !!sym("value")
    )

  scenario_data <- scenario_data |>
    mutate(
      org = ics_code
    ) |>
    select(!c("domain")) |>
    tidyr::pivot_longer(
      cols = !c("metric", "org"),
      names_to = "year",
      names_transform = as.integer,
      values_to = "value"
    ) |>
    tidyr::pivot_wider(
      names_from = !!sym("metric"),
      values_from = !!sym("value")
    ) |>
    left_join(
      performance_data,
      by = join_by(
        !!sym("org"),
        !!sym("year")
      )
    ) |>
    create_lag_variables() |>
    filter(
      !!sym("year") >= 2023
    ) |>
    mutate(
      nhs_region = NA_character_,
      quarter = NA_integer_,
      month = NA_integer_,
      .after = !!sym("year")
    )

  prediction_years <- setdiff(
    scenario_data$year,
    performance_data$year
  )

  for (yr in prediction_years) {

    next_scenario_year <- scenario_data |>
      filter(
        !!sym("year") <= yr
      )

    year_index <- next_scenario_year |>
      select("year", "org")

    # create the predictions for the performance variables for the year of interest
    # browser()
    predictions <- purrr::lmap(
      model,
      .f = (\(x) make_predictions(x, input_data = next_scenario_year))
    ) |>
      setNames(
        nm = names(model)
      ) |>
      lapply(
        bind_cols,
        year_index
      ) |>
      bind_rows(
        .id = "metric"
      ) |>
      select(
        "metric",
        "year",
        "org",
        value = ".pred"
      ) |>
      filter(
        !!sym("year") == yr
      ) |>
      # extend the table to future years so the lag versions of the performance
      # variables can be filled
      tidyr::complete(
        year = seq(
          from = yr,
          to = yr + 2,
          by = 1
        ),
        !!sym("org"),
        !!sym("metric")
      ) |>
      tidyr::pivot_wider(
        names_from = !!sym("metric"),
        values_from = !!sym("value")
      ) |>
      create_lag_variables()

    scenario_data <- update_scenario_performance_data_with_predictions(
      scenario_data = scenario_data,
      prediction_data = predictions
    )
  }

  predictions <- scenario_data |>
    tidyr::pivot_longer(
      cols = !c("year", "org", "nhs_region", "quarter", "month"),
      names_to = "metric",
      values_to = "value"
    ) |>
    filter(
      !!sym("metric") %in% names(performance_data)
    )

  return(predictions)

}


#' add fields for lagged versions of the variables
#'
#' @param data tibble to create lagged variables from
#' @param lagged_years number of years to lag
#' @importFrom rlang set_names sym
#' @importFrom purrr partial map map_df
#' @importFrom dplyr arrange across any_of group_by group_split mutate
#'   lag
#' @return tibble with additional columns to the input tibble that represent
#'   lagged versions of the input data
#' @noRd
create_lag_variables <- function(data, lagged_years = 2) {
  map_lag <- set_names(
    seq_len(lagged_years),
    nm = paste("lag", seq_len(lagged_years), sep = "_")
  ) |>
    map(
      ~ purrr::partial(lag, n = .x)
    )

  lag_vars <- setdiff(
    names(data),
    c("org", "year")
  )

  data <- data |>
    arrange(
      across(
        any_of(
          c("year", "quarter", "month", "org")
        )
      )
    ) |>
    group_by(!!sym("org")) |>
    group_split() |>
    purrr::map_df(
      ~ mutate(
        .x,
        across(
          all_of(lag_vars),
          .fn = map_lag,
          .names = "{.fn}_{.col}"
        )
      )
    )

  return(data)
}


#' Replace values in teh scenario dataset with predicted values in the
#' prediction dataset. This includes lagged versions of the metrics. Any values
#' in the scenario dataset should be retained, and only NAs should be replaced
#'
#' @param scenario_data a wide tibble with fields "org", "year", "nhs_region",
#'   "quarter", "month" and then a field for any metric
#' @param prediction_data a wider dataset with field for "org" and "year" and
#'   then a field for any metric
#'
#' @importFrom tidyr pivot_longer pivot_wider
#' @importFrom dplyr filter setdiff rows_update
#' @importFrom rlang sym
#'
#' @return a tibble of identical dimensions to the scenario dataset, but with
#'   some values for the metrics replaced
#' @noRd
update_scenario_performance_data_with_predictions <- function(scenario_data, prediction_data) {
  required_scenario_names <- c("org", "year", "nhs_region", "quarter", "month")
  if (!all(required_scenario_names %in% names(scenario_data))) {
    missing_names <- setdiff(
      required_scenario_names,
      names(scenario_data)
    )
    stop(
      paste(
        paste(missing_names, collapse = ", "),
        "fields are missing from scenario_data"
      )
    )
  }

  required_prediction_names <- c("org", "year")
  if (!all(required_prediction_names %in% names(prediction_data))) {
    missing_names <- setdiff(
      required_prediction_names,
      names(prediction_data)
    )
    stop(
      paste(
        paste(missing_names, collapse = ", "),
        "fields are missing from prediction_data"
      )
    )
  }

  prediction_data_long <- prediction_data |>
    pivot_longer(
      cols = !c("org", "year"),
      names_to = "metric",
      values_to = "value"
    ) |>
    filter(!is.na(!!sym("value")))

  scenario_data <- scenario_data |>
    pivot_longer(
      cols = !c("org", "year", "nhs_region", "quarter", "month"),
      names_to = "metric",
      values_to = "value"
    ) |>
    dplyr::rows_update(
      y = prediction_data_long,
      by = c("year", "org", "metric"),
      unmatched = "ignore" # this occurs for the final years of scenario_data as the lagged prediction fields extend beyond the time period in scenario data
    ) |>
    tidyr::pivot_wider(
      names_from = !!sym("metric"),
      values_from = !!sym("value")
    )

  return(scenario_data)
}


#' Understand the model object
#'
#' @param model named list containing workflow object as only item. The name
#'   should be the target variable name
#'
#' @return tibble with two fields, engine, which describes the type of model
#'   (eg, glmnet or randomForest), and model_type, which describe whether the
#'   model is modelling a proportion or a difference from a previous value
#'
#' @details to understand whether the model type is a difference from previous
#'   value model, the function looks for whether any of the input variables have
#'   a negative value. If they do, then the model is considered a "difference
#'   from previous" model
#'
#' @importFrom hardhat extract_mold
#' @importFrom purrr pluck
#' @importFrom dplyr tibble
#' @noRd
model_descriptions <- function(model) {
  engine <- model |>
    hardhat::extract_fit_engine() |>
    class()

  negative_values <- model |>
    hardhat::extract_mold() |>
    purrr::pluck("predictors") |>
    (\(x) x < 0)() |>
    any()

  model_type <- ifelse(negative_values, "difference", "proportion")

  output <- tibble(
    engine = engine[1],
    model_type = model_type
  )
  return(output)
}


#' Caculate predictions from model and input data
#'
#' @param model named list containing workflow object as only item. The name
#'   should be the target variable name
#' @param input_data tibble where all the field are input variables for the
#'   models
#'
#' @details the function understands from the components of the workflow object
#'   whether the model is modelling a proportion target variable or a difference
#'   from previous year. If it is the latter, it will apply the difference to
#'   the previous year's value to create the prediction.
#'
#' @return tibble with one field, named .pred, which is the prediction for the
#'   target variable defined by the name of the list item passed in through the
#'   model object
#'
#' @importFrom purrr pluck
#' @importFrom dplyr select all_of bind_cols mutate lag
#' @importFrom rlang sym
#' @importFrom hardhat extract_fit_parsnip
#' @noRd
make_predictions <- function(model, input_data) {

  target_variable <- names(model)

  # get workflow from model list
  wf <- model |>
    purrr::pluck(1)

  model_configuration <- model_descriptions(wf)

  if ("difference" %in% model_configuration$model_type) {

    observed_target <- input_data |>
      select(
        all_of(target_variable)
      )

    input_data <- input_data |>
      arrange(org, year) |>
      mutate(
        across(
          !any_of(c("year", "quarter", "month", "org", "nhs_region", "pandemic_onwards")),
          function(x) x - lag(x, default = 0)
        ),
        .by = c(
          org
        )
      )
  }

  if (grepl("glm", model_configuration$engine)) {
    lambda <- wf |>
      hardhat::extract_fit_parsnip() |>
      pluck("spec", "args", "penalty")

    prediction <- predict(
      wf,
      new_data = input_data,
      penalty = lambda
    )
  } else if (grepl("random", model_configuration$engine)) {
    prediction <- predict(
      wf,
      new_data = input_data
    )
  }


  if ("difference" %in% model_configuration$model_type) {
    observed_target <- input_data |>
      select(
        all_of(target_variable)
      )

    prediction <- bind_cols(
      prediction, observed_target
    ) |>
      mutate(
        !!sym(".pred") := !!sym(".pred") + lag(!!sym(target_variable))
      ) |>
      select(!all_of(c(target_variable)))
  }

  return(prediction)
}