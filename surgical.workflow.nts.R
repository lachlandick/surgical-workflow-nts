# 
# Surgical workflow patterns as indicators of non-technical performance

# Analysis pipeline
# Author: Lachlan Dick
# Email: lachlan.dick@ed.ac.uk

# This analysis pipeline is for creating surgical workflow patterns from temporally labelled data. The source data is not available and so your own data should be used. 
# If using this code, the following reference should be cited:
# TBC


# =============================================================================

# ---- Required packages ---- 
# If not installed, run install.packages("package_title") first and then call from library. 

library(readxl)    # Reads the annotation spreadsheet. This is required for .xlsx file types only. 
library(dplyr)     # Data manipulation
library(tidyr)     # Reshaping to a video x pattern matrix
library(tidytext)  # TF-IDF calculation
library(caret)     # Stratified cross-validation folds
library(glmnet)    # LASSO logistic regression
library(pROC)      # AUROC
library(PRROC)     # AUPRC


# =============================================================================

# Input data requirements:
# The spreadsheet needs one row per annotated gesture sequence, in temporal order within each video, with the columns:  "dexterity", "action", "target", "instrument". 
# The columns "video" and "phase" are also needed and spelling must match. 

input_file = "file pathname here" # Insert the source pathname here.
output_dir = "output"

seed   = 123   # Random seed
n_boot = 1000  # Number of bootstrap iterations created in Step 6
nfolds = 5     # The number of cross-validation folds used for identifying the optimal regularisation parameter (lambda) in Step 7.  

# Assign videos within dataset to either high ('nts_high') or average ('nts_not_high') performance groups. 
# For the published manuscript, the top quartile are allocated as high with all others assigned average.
# The allocation used in the published manuscript is provided for example. This should be replaced with your own. 

nts_high = c("LAP006", "LAP012", ...)       # full list
nts_not_high = c("LAP001", "LAP002", ...)   # full list

# Prepare output folder. 
dir.create(output_dir, showWarnings = FALSE)


# =============================================================================

# ---- STEP 1: Load and tidy the annotations ----
# This stage imports the data and prepares it for analysis. 
# Redundant columns are removed and the individual gesture variables are combined into a single gesture sequence.
# dexterity, action, target, instrument becomes dexterityactiontargetinstrument

data = read_excel(input_file)
data = data[, c("video", "phase", "dexterity", "action", "target", "instrument")]
data = na.omit(data)

data = data.frame(
  video    = data$video,
  phase    = data$phase,
  sequence = paste0(data$dexterity, data$action, data$target, data$instrument),
  stringsAsFactors = FALSE
)

# =============================================================================

# ---- STEP 2: Build surgical workflow patterns ----
# A sliding window of three consecutive gesture sequences forms each pattern.
# Windows are confined within each video, so no pattern spans two videos.
# The code assumes that annotations are already in correct timeseries order. 

create_patterns_from_sequences = function(df) {
  n = nrow(df)
  if (n < 3) return(NULL)  # Too few gestures to form a pattern.
  
  data.frame(
    video   = df$video[1:(n - 2)],
    phase   = df$phase[1:(n - 2)],  # Phase of the first gesture in the window.
    pattern = paste(df$sequence[1:(n - 2)], 
                    df$sequence[2:(n - 1)],
                    df$sequence[3:n]),
    stringsAsFactors = FALSE
  )
}

data = data %>%
  group_by(video) %>%
  group_split() %>%
  lapply(create_patterns_from_sequences) %>%
  bind_rows() %>%
  mutate(pattern = gsub("\\s+", "", pattern))


# =============================================================================

# ---- STEP 3: Assign NTS performance groups to patterns ----
# This stage assigns labels to the a priori defined videos. 
# Before running, ensure that videos are correctly assigned to nts_high and nts_not_high and that there are no duplicates.

data = data %>%
  mutate(nts_group = case_when(
    video %in% nts_high     ~ "High",
    video %in% nts_not_high ~ "Not_high",
    TRUE                    ~ "Unclassified"
  ))

stopifnot(!any(data$nts_group == "Unclassified"))


# =============================================================================

# ---- STEP 4: Text feature scoring of surgical workflow patterns ----
# Term Frequency-Inverse Document Frequency (TF-IDF) is calculated for each pattern in each video by determining its frequency in that video versus the entire dataset. 
# Where patterns appear in more than one video, the mean TF-IDF value across those videos is used as the summary pattern TF-IDF value. 
# After this stage, each unique pattern has a single TF-IDF value.

pattern_tfidf = data %>%
  count(video, pattern, name = "n") %>%
  bind_tf_idf(term = pattern, document = video, n = n)

mean_tfidf_per_pattern = pattern_tfidf %>%
  group_by(pattern) %>%
  summarise(mean_tfidf = mean(tf_idf, na.rm = TRUE))


# =============================================================================

# ---- STEP 5: Video x pattern matrix ----
# A matrix is created of one row per video, one column per unique pattern. 
# Each cell holds the represents the pattern's aggregate TF-IDF if the pattern occurs in that video.
# If the pattern is absent from the video, the cell content is 0. 

video_labels = data %>% distinct(video, nts_group)

pattern_matrix = pattern_tfidf %>%
  select(video, pattern) %>%
  left_join(mean_tfidf_per_pattern, by = "pattern") %>%
  pivot_wider(names_from = pattern, values_from = mean_tfidf, values_fill = 0) %>%
  left_join(video_labels, by = "video")


# =============================================================================

# ---- STEP 6: Stratified bootstrap and 80:20 train/test split ----
# Bootstrapping with replacement (1000 iterations) of the matrix is performed. Videos are stratified by NTS group to preserve group allocations. 
# Each iteration is then split randomly using an 80:20 train/test split. 

bootstrap_matrix_stratified = function(mat) {
  mat %>%
    group_by(nts_group) %>%
    group_modify(~ .x[sample(nrow(.x), replace = TRUE), ]) %>%
    ungroup()
}

set.seed(seed)
boot_matrices = replicate(n_boot, bootstrap_matrix_stratified(pattern_matrix),
                          simplify = FALSE)

set.seed(seed)
train_test_list = lapply(boot_matrices, function(mat) {
  n_rows    = nrow(mat)
  train_idx = sample(1:n_rows, floor(0.8 * n_rows))
  test_idx  = setdiff(1:n_rows, train_idx)
  list(train = mat[train_idx, , drop = FALSE],
       test  = mat[test_idx, , drop = FALSE])
})


# =============================================================================

# ---- STEP 7: LASSO logistic regression ----
# In each iteration:
#   - High NTS videos are weighted 3:1 to account for class imbalance. In the published manuscript, this weighting reflects the imbalance in the source dataset. This should be adjusted if class imbalance changes. 
#   - The optimal regularisation parameter (lambda) is chosen by stratified 5-fold cross-validation
#   - The model is refitted on the full training set at that lambda
#   - AUROC and AUPRC are calculated on the test set (High = positive class) as a secondary analysis. 

set.seed(seed)

final_models_list = vector("list", n_boot)
auroc_values      = rep(NA_real_, n_boot)
auprc_values      = rep(NA_real_, n_boot)

for (i in seq_len(n_boot)) {
  
  train_mat = train_test_list[[i]]$train
  test_mat  = train_test_list[[i]]$test
  
  x_train = as.matrix(train_mat %>% select(-video, -nts_group))
  y_train = factor(train_mat$nts_group, levels = c("Not_high", "High"))
  class_weights = ifelse(y_train == "High", 3, 1)
  
  # Skip if the training set lacks at least two videos of each group
  class_counts = table(y_train)
  if (length(class_counts) < 2 || min(class_counts) < 2) next
  
  foldid = createFolds(y_train, k = nfolds, list = FALSE)
  
  x_test = as.matrix(test_mat %>% select(-video, -nts_group))
  y_test = factor(test_mat$nts_group, levels = c("Not_high", "High"))
  
  # Skip if the test set does not contain both groups
  if (length(unique(y_test)) < 2) next
  
  cv_fit = cv.glmnet(x = x_train, y = y_train, family = "binomial",
                     alpha = 1, foldid = foldid, weights = class_weights)
  
  final_model = glmnet(x = x_train, y = y_train, family = "binomial",
                       alpha = 1, lambda = cv_fit$lambda.min,
                       weights = class_weights)
  final_models_list[[i]] = final_model
  
  test_prob = as.numeric(predict(final_model, newx = x_test, type = "response"))
  
  roc_obj = roc(y_test, test_prob, quiet = TRUE)
  auroc_values[i] = as.numeric(auc(roc_obj))
  
  pr_obj = pr.curve(scores.class0 = test_prob[y_test == "High"],
                    scores.class1 = test_prob[y_test == "Not_high"],
                    curve = FALSE)
  auprc_values[i] = pr_obj$auc.integral
}


# =============================================================================

# ---- STEP 8: Model performance summary ----
# Mean, median, SD and 95% percentile interval (2.5th-97.5th) are determined for reporting. 

results_df = data.frame(iteration = seq_len(n_boot),
                        AUROC = auroc_values,
                        AUPRC = auprc_values)

summarise_metric = function(x) {
  x = x[!is.na(x)]
  data.frame(n_iterations = length(x),
             mean   = mean(x),
             median = median(x),
             sd     = sd(x),
             ci_lower = unname(quantile(x, 0.025)),
             ci_upper = unname(quantile(x, 0.975)))
}

performance_summary = bind_rows(
  cbind(metric = "AUROC", summarise_metric(auroc_values)),
  cbind(metric = "AUPRC", summarise_metric(auprc_values))
)

print(performance_summary)


# =============================================================================

# ---- STEP 9: Feature selection summary ----
# The following are determined for each pattern: 
#   - The number and percentage of iterations in which it was selected (for non-zero coefficient patterns only).
#   - The mean coefficient value and 95% CI across iterations.
#   - The number of videos in the source dataset that the pattern was present in.
# For presentation, patterns are ordered by selection frequency.

fitted_models = Filter(Negate(is.null), final_models_list)

# Number of patterns selected per model
n_features_selected = sapply(fitted_models, function(model) {
  sum(coef(model)[-1, 1] != 0)
})

cat(sprintf(
  "\nPatterns selected per model: mean = %.1f, SD = %.1f, median = %.1f, 95%% interval = [%.1f, %.1f]\n",
  mean(n_features_selected), sd(n_features_selected), median(n_features_selected),
  quantile(n_features_selected, 0.025), quantile(n_features_selected, 0.975)
))

# Non-zero coefficients from every fitted model
coef_df = bind_rows(lapply(fitted_models, function(model) {
  coefs = coef(model)[-1, 1]
  coefs = coefs[coefs != 0]
  data.frame(feature = names(coefs), coef = unname(coefs))
}))

feature_counts = table(coef_df$feature)

coef_stats = coef_df %>%
  group_by(feature) %>%
  summarise(mean_coef = mean(coef),
            ci_lower  = quantile(coef, 0.025),
            ci_upper  = quantile(coef, 0.975),
            .groups = "drop")

video_counts = data %>%
  group_by(pattern) %>%
  summarise(n_videos = n_distinct(video), .groups = "drop") %>%
  rename(feature = pattern)

feature_summary = data.frame(
  feature = names(feature_counts),
  count   = as.integer(feature_counts),
  percent = 100 * as.integer(feature_counts) / n_boot
) %>%
  left_join(coef_stats, by = "feature") %>%
  left_join(video_counts, by = "feature") %>%
  mutate(pct_videos = round(100 * n_videos / n_distinct(data$video), 1)) %>%
  arrange(desc(count))

print(head(feature_summary, 10))


# =============================================================================
# Save results
# =============================================================================

write.csv(results_df,          file.path(output_dir, "performance_by_iteration.csv"), row.names = FALSE)
write.csv(performance_summary, file.path(output_dir, "performance_summary.csv"),      row.names = FALSE)
write.csv(feature_summary,     file.path(output_dir, "feature_summary.csv"),          row.names = FALSE)
writeLines(capture.output(sessionInfo()), file.path(output_dir, "session_info.txt"))