function print_labeled_vector(name, v, labels)
%PRINT_LABELED_VECTOR Print vector v with one named entry per line.
    for i = 1:numel(v)
        fprintf('  %s.%-16s = %8.4f\n', name, labels{i}, v(i));
    end
end
