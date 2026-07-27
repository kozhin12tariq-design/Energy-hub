function print_labeled_matrix(M, rowLabels, colLabels)
%PRINT_LABELED_MATRIX Print matrix M with row/column name headers.
    fprintf('%18s', '');
    for j = 1:numel(colLabels)
        fprintf('%14s', colLabels{j});
    end
    fprintf('\n');
    for i = 1:numel(rowLabels)
        fprintf('%18s', rowLabels{i});
        for j = 1:size(M,2)
            fprintf('%14.4f', M(i,j));
        end
        fprintf('\n');
    end
end
