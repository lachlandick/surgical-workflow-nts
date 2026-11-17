# Surgical workflow patterns as indicators of non-technical performance

Analysis code accompanying:

> Dick L, et al. *Surgical workflow patterns as indicators of non-technical performance.* 2026

Code archive DOI: [Zenodo DOI]

## Overview

This R script identifies surgical workflow patterns associated with high non-technical skills (NTS) performance in laparoscopic surgery. It uses annotated gesture data from operative videos. For details on the source dataset used and annotation pipeline, see the supporting reference:

Dick L, et al. Identifying novel indicators of non-technical skills derived from operative video annotation. Br J Surg. 2026 Mar 4;113(3):znag015.

The pipeline:

1. **Load and tidy annotations.** Each annotated gesture's `dexterity`, `action`, `target` and `instrument` codes are combined into a single gesture sequence.
2. **Build workflow patterns.** A sliding window of three consecutive gesture sequences forms each pattern. Windows are confined within each video.
3. **Assign performance groups.** Each video is labelled `High` or `Not_high` NTS performance, using a predefined allocation.
4. **Score patterns with TF-IDF.** Term frequency–inverse document frequency is calculated for each pattern in each video. Each pattern's values are then averaged across the videos in which it occurs.
5. **Build a video × pattern matrix.** There is one row per video and one column per pattern.
6. **Bootstrap and split.** The matrix is resampled 1000 times, stratified by NTS group, and each resample is split 80:20 into training and test sets.
7. **Fit LASSO logistic regression.** In each iteration, lambda is selected by stratified 5-fold cross-validation, and the model is evaluated on the test set (AUROC and AUPRC).
8. **Summarise model performance** across iterations.
9. **Summarise feature selection.** For each pattern, this reports how often it was selected, its coefficients, and how many videos contain it.

## Repository contents

| File | Description |
|---|---|
| `surgical.workflow.nts.R` | Full analysis pipeline |
| `LICENSE` | Licence terms |

## Requirements

- R [Version 2024.04.2+764]
- R packages: `readxl`, `dplyr`, `tidyr`, `tidytext`, `caret`, `glmnet`, `pROC`, `PRROC`

To install the packages:

```r
install.packages(c("readxl", "dplyr", "tidyr", "tidytext", "caret", "glmnet", "pROC", "PRROC"))
```

## Input data

The script reads a single Excel spreadsheet (`.xlsx`). It reads the first sheet by default; to use a different sheet, add `sheet = ` to `read_excel()`. The spreadsheet needs one row per annotated gesture, with these columns:

| Column | Description |
|---|---|
| `video` | Video identifier. Must match the IDs used in `nts_high` and `nts_not_high` exactly, including case and spaces |
| `phase` | Operative phase (required by the script as used to generate heat maps in published manuscript, but not used in the analysis) |
| `dexterity` | Gesture dexterity code |
| `action` | Gesture action code |
| `target` | Gesture target code |
| `instrument` | Gesture instrument code |

Rows must be in temporal order within each video. The script doesn't sort them. Rows with any missing value in these columns are removed.

## How to run

1. Open `surgical.workflow.nts.R` in R or RStudio.
2. Set R's working directory to where you want results saved. The `output` folder is created there.
3. Edit the settings at the top of the script:
   - `input_file`: path to your annotation spreadsheet.
   - `nts_high` and `nts_not_high`: the video IDs in each performance group. Every video in the data must be in exactly one group. In the published analysis, videos in the top quartile of NTS rating were classed as `High` and all others as `Not_high`.
4. If your group sizes differ from the published study, adjust the class weighting in Step 7. The published analysis weighted `High` videos 3:1, approximately the ratio of `Not_high` to `High` videos.
5. Run the whole script.

**Expected behaviour:**

- `cv.glmnet` may print warnings about few observations per fold. These are expected with small groups.
- Iterations where the training or test set doesn't contain both groups are skipped. The number of iterations used is reported in `performance_summary.csv`.

## Outputs

These files are written to the `output` folder:

| File | Contents |
|---|---|
| `performance_by_iteration.csv` | AUROC and AUPRC for each bootstrap iteration (`NA` for skipped iterations) |
| `performance_summary.csv` | For AUROC and AUPRC: number of iterations used, mean, median, SD, and 2.5th–97.5th percentile interval |
| `feature_summary.csv` | One row per selected pattern (see below) |
| `session_info.txt` | R and package versions used for this run |

Columns in `feature_summary.csv`:

| Column | Description |
|---|---|
| `feature` | The pattern: three consecutive gesture sequences joined together |
| `count` | Number of iterations in which the pattern was selected (non-zero coefficient) |
| `percent` | `count` as a percentage of `n_boot` |
| `mean_coef` | Mean coefficient across the iterations in which the pattern was selected. Positive values indicate association with `High` NTS performance |
| `ci_lower`, `ci_upper` | 2.5th and 97.5th percentiles of the coefficient across those iterations |
| `n_videos` | Number of videos in the dataset containing the pattern |
| `pct_videos` | `n_videos` as a percentage of all videos |

The script also prints the performance summary, the number of patterns selected per model, and the top 10 patterns to the console.

## Citation

If you use this code, please cite the paper above and the code archive:

> Dick L. surgical.workflow.nts (Version v1.0). Zenodo. [Zenodo DOI]

## Contact

Lachlan Dick: lachlan.dick@ed.ac.uk
